/**
 * @description Domain triggers insert event-only Sharing_Queue__c rows (Job__c blank).
 * SharingQueueTriggerHandler expands the catalog chain onto those rows.
 * Workers claim queue instances, write Job_Execution__c, and run handlers
 * from Job__r.Handler__c.
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueService {

    public static final String STATUS_BLOCKED    = 'Blocked';
    public static final String STATUS_PENDING    = 'Pending';
    public static final String STATUS_PROCESSING = 'Processing';
    public static final String STATUS_COMPLETED  = 'Completed';
    public static final String STATUS_FAILED     = 'Failed';
    public static final String STATUS_CANCELLED  = 'Cancelled';

    public static final Integer MAX_RETRIES        = 3;
    public static final Integer QUEUEABLE_LIMIT    = 50;
    public static final Integer BATCH_CLAIM_LIMIT  = 40;
    public static final Integer LAST_ERROR_MAX_LEN = 32768;

    public static final String STUCK_MESSAGE = 'Stuck in Processing (LastAttemptDate older than 2 hours)';

    /** Slice being processed by SharingQueueBatch.execute (config Id). */
    public static Id activeSliceConfigId;

    /**
     * When true, enqueueOnce / startIfPending no-op so a volume harness can
     * drain Queueable and Batch synchronously without Test.stopTest().
     */
    public static Boolean suppressAsyncKick = false;

    public static final String QUEUEABLE_WORKER = 'SharingQueueQueueable';
    public static final String BATCH_WORKER     = 'SharingQueueBatch';

    private static final List<String> ACTIVE_ASYNC_STATUSES = new List<String>{
        'Holding', 'Queued', 'Preparing', 'Processing'
    };

    /** Test overlay: skip live AsyncApexJob so tests do not depend on the flex queue. */
    @TestVisible static Integer activeQueueableOverride;
    @TestVisible static Integer activeBatchOverride;

    private static Boolean compactedThisTx = false;

    /**
     * @description Clears the once-per-transaction compaction guard so a test can compact again.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestVisible
    static void resetCompactGuard() {
        compactedThisTx = false;
    }

    private static final List<String> OPEN_STATUSES = new List<String>{
        STATUS_BLOCKED, STATUS_PENDING, STATUS_PROCESSING
    };

    /**
     * @description Queues claimed by a worker and the Job Execution rows created for them.
     * @author Melissa Rainboldt
     */
    public class ClaimResult {
        public List<Sharing_Queue__c> queues;
        public Map<Id, Job_Execution__c> executionsByQueueId;
        /**
         * @description Creates an empty claim with no queues and no job executions.
         * @author Melissa Rainboldt
         * @return A new ClaimResult instance.
         */
        public ClaimResult() {
            queues = new List<Sharing_Queue__c>();
            executionsByQueueId = new Map<Id, Job_Execution__c>();
        }
    }

    /**
     * @description JSON payload stored on a Sharing Queue row: principal, access, related objects,
     * and the batch cursor.
     * @author Melissa Rainboldt
     */
    public class Payload {
        public String userOrGroupId;
        public String accessLevel;
        public String rowCause;
        public String relatedObjectApiName;
        public List<String> relatedObjectApiNames;
        public String cursorObject;
        public String cursorLastId;

        /**
         * @description Serializes the populated payload fields, including the cursor when one is
         * set.
         * @author Melissa Rainboldt
         * @return The payload JSON.
         */
        public String toJson() {
            Map<String, Object> m = new Map<String, Object>();
            if (String.isNotBlank(userOrGroupId)) m.put('userOrGroupId', userOrGroupId);
            if (String.isNotBlank(accessLevel)) m.put('accessLevel', accessLevel);
            if (String.isNotBlank(rowCause)) m.put('rowCause', rowCause);
            if (String.isNotBlank(relatedObjectApiName)) {
                m.put('relatedObjectApiName', relatedObjectApiName);
            }
            if (relatedObjectApiNames != null && !relatedObjectApiNames.isEmpty()) {
                m.put('relatedObjectApiNames', relatedObjectApiNames);
            }
            if (String.isNotBlank(cursorObject) || String.isNotBlank(cursorLastId)) {
                m.put('cursor', new Map<String, Object>{
                    'object' => cursorObject
                   ,  'lastId' => cursorLastId
                });
            }
            return JSON.serialize(m);
        }
    }

    /**
     * @description Parses payload JSON. Blank JSON returns an empty payload.
     * @author Melissa Rainboldt
     * @param json Payload JSON from Sharing_Queue__c.Payload__c. Blank returns an empty payload.
     * @return The parsed payload. Blank JSON returns an empty payload.
     */
    public static Payload parsePayload(String json) {
        Payload payload= new Payload();
        if (String.isBlank(json)) return payload;
        Map<String, Object> raw = (Map<String, Object>)System.JSON.deserializeUntyped(json);

        payload.userOrGroupId = (String) raw.get('userOrGroupId');
        payload.accessLevel = (String) raw.get('accessLevel');
        payload.rowCause = (String) raw.get('rowCause');
        payload.relatedObjectApiName = (String) raw.get('relatedObjectApiName');
        Object names = raw.get('relatedObjectApiNames');
        if (names instanceof List<Object>) {
            payload.relatedObjectApiNames = new List<String>();
            for (Object obj : (List<Object>) names) {
                if (obj != null) payload.relatedObjectApiNames.add(String.valueOf(obj));
            }
        }

        Map<String, Object> cursor = (Map<String, Object>) raw.get('cursor');
        if (cursor != null) {
            Object objName = cursor.get('object');
            Object lastId = cursor.get('lastId');
            if (objName != null) payload.cursorObject = String.valueOf(objName);
            if (lastId != null) payload.cursorLastId = String.valueOf(lastId);
        }
        return payload;
    }

    //Domain enqueue (event rows only)

    /**
     * @description Inserts event-only queue rows for team member changes. Open work for the same
     * main, job, source, and application is skipped.
     * @author Melissa Rainboldt
     * @param records Team member records from the triggering transaction.
     * @param oldMap Prior team member values keyed by Id. Null on insert.
     * @param triggerEvent Catalog event, such as TeamMemberCreated or TeamMemberUpdated.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The number of Sharing Queue rows inserted.
     */
    public static Integer enqueueFromTeamMembers(
            List<SObject> records,
            Map<Id, SObject> oldMap,
            String triggerEvent,
            String application) {
        if (records == null || records.isEmpty() || String.isBlank(application)) return 0;
        if (!SharingUtils.isSharingQueueEnabled()) return 0;

        SharingConfigService cfg = SharingConfigService.getInstance(application);
        SharingConfigService.TeamMemberConfig tmc = cfg.teamMemberConfig;
        Job__c head = JobCatalogService.headJobFor(triggerEvent, application);

        List<Sharing_Queue__c> events = new List<Sharing_Queue__c>();
        Set<String> keysThisCall = new Set<String>();
        Set<Id> sourceIds = new Set<Id>();
        Set<String> mainIds = new Set<String>();

        for (SObject rec : records) {
            if (!isRelevantTeamMemberChange(rec, oldMap, tmc)) continue;
            Id sourceId = (Id) rec.get('Id');
            Id mainId = (Id) rec.get(tmc.parentLookupField);
            if (sourceId != null) sourceIds.add(sourceId);
            if (mainId != null) mainIds.add(String.valueOf(mainId));
        }
        Set<String> existingKeys = queryOpenKeys(mainIds, head, sourceIds, triggerEvent, application);

        for (SObject rec : records) {
            if (!isRelevantTeamMemberChange(rec, oldMap, tmc)) continue;
            Id mainId = (Id) rec.get(tmc.parentLookupField);
            Id sourceId = (Id) rec.get('Id');
            Id principalId = TeamMemberSharingService.userOrGroupId(rec, tmc);
            if (mainId == null || sourceId == null || principalId == null) continue;

            String key = coalesceKey(
                String.valueOf(mainId),
                head == null ? null : head.Id,
                String.valueOf(sourceId),
                application);
            if (existingKeys.contains(key) || keysThisCall.contains(key)) continue;
            keysThisCall.add(key);

            Payload payload = new Payload();
            payload.userOrGroupId = principalId == null ? null : String.valueOf(principalId);
            payload.accessLevel = resolveShareLevel(
                cfg,
                TeamMemberSharingService.stringValue(rec, tmc.roleField),
                TeamMemberSharingService.stringValue(rec, tmc.accessLevelField));
            payload.rowCause = rowCauseForObject(
                cfg, mainId.getSObjectType().getDescribe().getName());
            payload.relatedObjectApiNames = relatedObjectApiNames(cfg);

            events.add(newEvent(
                mainId,
                mainId.getSObjectType().getDescribe().getName(),
                triggerEvent,
                sourceId,
                tmc.objectApiName,
                payload.toJson(),
                application));
        }
        return insertEvents(events);
    }

    /**
     * @description Inserts event-only queue rows for related records. Open work for the same main,
     * job, and source is skipped.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the related child object.
     * @param records Related child records that were inserted.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The number of Sharing Queue rows inserted.
     */
    public static Integer enqueueFromRelatedRecords(
            String objectApiName,
            List<SObject> records,
            String application) {
        if (String.isBlank(objectApiName) || records == null || records.isEmpty()
                || String.isBlank(application)) {
            return 0;
        }
        if (!SharingUtils.isSharingQueueEnabled()) return 0;

        SharingConfigService cfg = SharingConfigService.getInstance(application);
        SharingConfigService.ObjectConfig oc =
            cfg.objectConfigByApiName.get(objectApiName.toLowerCase());
        if (oc == null) return 0;

        records = cfg.hydrateRelatedRecords(objectApiName, records);

        String triggerEvent = JobCatalogService.EVENT_RELATED_RECORD_CREATED;
        Job__c head = JobCatalogService.headJobFor(triggerEvent, application);

        Set<Id> sourceIds = new Set<Id>();
        Set<String> mainIds = new Set<String>();
        for (SObject rec : records) {
            Id sourceId = (Id) rec.get('Id');
            if (sourceId != null) sourceIds.add(sourceId);
            for (Id mainId : oc.parentIdsOn(rec)) {
                mainIds.add(String.valueOf(mainId));
            }
        }
        Set<String> existingKeys = queryOpenKeys(mainIds, head, sourceIds, triggerEvent, application);

        List<Sharing_Queue__c> events = new List<Sharing_Queue__c>();
        Set<String> keysThisCall = new Set<String>();
        for (SObject rec : records) {
            Id sourceId = (Id) rec.get('Id');
            if (sourceId == null) continue;
            for (Id mainId : oc.parentIdsOn(rec)) {
                String key = coalesceKey(
                    String.valueOf(mainId),
                    head == null ? null : head.Id,
                    String.valueOf(sourceId),
                    application);
                if (existingKeys.contains(key) || keysThisCall.contains(key)) continue;
                keysThisCall.add(key);

                Payload payload = new Payload();
                payload.relatedObjectApiName = objectApiName;
                payload.rowCause = oc.rowCause;
                events.add(newEvent(
                    mainId,
                    mainId.getSObjectType().getDescribe().getName(),
                    triggerEvent,
                    sourceId,
                    objectApiName,
                    payload.toJson(),
                    application));
            }
        }
        return insertEvents(events);
    }

    /**
     * @description Inserts one reconcile event per main that does not already have open work for
     * that job.
     * @author Melissa Rainboldt
     * @param mainIds Main record Ids that need a rebuild.
     * @param triggerEvent Catalog event. Blank defaults to ReconcileSweep.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The number of Sharing Queue rows inserted.
     */
    public static Integer enqueueReconcileForMains(
            Set<Id> mainIds,
            String triggerEvent,
            String application) {
        if (mainIds == null || mainIds.isEmpty() || String.isBlank(application)) return 0;
        if (!SharingUtils.isSharingQueueEnabled()) return 0;
        String event = String.isBlank(triggerEvent)
            ? JobCatalogService.EVENT_RECONCILE_SWEEP
            : triggerEvent;
        Job__c head = JobCatalogService.headJobFor(event, application);

        SharingConfigService cfg = SharingConfigService.getInstance(application);
        Set<String> mainIdStrings = new Set<String>();
        for (Id mainId : mainIds) {
            if (mainId != null) mainIdStrings.add(String.valueOf(mainId));
        }
        Set<String> existingKeys = queryOpenKeys(mainIdStrings, head, new Set<Id>(), event, application);

        Payload payload = new Payload();
        payload.relatedObjectApiNames = relatedObjectApiNames(cfg);
        payload.rowCause = firstRowCause(cfg);
        String json = payload.toJson();

        List<Sharing_Queue__c> events = new List<Sharing_Queue__c>();
        Set<String> keysThisCall = new Set<String>();
        for (Id mainId : mainIds) {
            if (mainId == null) continue;
            String key = coalesceKey(
                String.valueOf(mainId),
                head == null ? null : head.Id,
                null,
                application);
            if (existingKeys.contains(key) || keysThisCall.contains(key)) continue;
            keysThisCall.add(key);
            events.add(newEvent(
                mainId,
                mainId.getSObjectType().getDescribe().getName(),
                event,
                null,
                null,
                json,
                application));
        }
        return insertEvents(events);
    }

    /**
     * @description Flow/Invocable path: insert event-only rows (Job blank). Object API names
     * come from the Ids. Trigger Event is passed through so OCC catalog keys
     * (e.g. OCC.LegalTeamMember.Created) keep working. After insert, the
     * trigger expands the catalog chain.
     * @author Melissa Rainboldt
     */
    public class EventRequest {
        public String application;
        public String triggerEvent;
        public Id mainRecordId;
        public Id sourceRecordId;
    }

    /**
     * @description Inserts one event-only row per complete request. Counts are aligned to the
     * request list.
     * @author Melissa Rainboldt
     * @param specs Event requests to enqueue.
     * @return How many rows were inserted for each request, in request order. Incomplete requests
     * contribute 0.
     */
    public static List<Integer> enqueueFromEventRequests(List<EventRequest> specs) {
        List<Integer> counts = new List<Integer>();
        if (specs == null || specs.isEmpty()) return counts;
        if (!SharingUtils.isSharingQueueEnabled()) {
            for (Integer i = 0; i < specs.size(); i++) {
                counts.add(0);
            }
            return counts;
        }

        List<Sharing_Queue__c> events = new List<Sharing_Queue__c>();
        List<Integer> eventIndexes = new List<Integer>();
        for (Integer i = 0; i < specs.size(); i++) {
            counts.add(0);
            EventRequest spec = specs[i];
            if (spec == null || spec.mainRecordId == null
                    || String.isBlank(spec.application)
                    || String.isBlank(spec.triggerEvent)) {
                continue;
            }
            String sourceApi = spec.sourceRecordId == null
                ? null
                : spec.sourceRecordId.getSObjectType().getDescribe().getName();
            events.add(newEvent(
                spec.mainRecordId,
                spec.mainRecordId.getSObjectType().getDescribe().getName(),
                spec.triggerEvent.trim(),
                spec.sourceRecordId,
                sourceApi,
                null,
                spec.application.trim()));
            eventIndexes.add(i);
        }
        if (events.isEmpty()) return counts;
        insertEvents(events);
        for (Integer i : eventIndexes) {
            counts.set(i, 1);
        }
        return counts;
    }

    //Chain expansion (Sharing_Queue after insert)

    /**
     * @description Writes the catalog chain onto event rows whose Job is blank, and fails rows that
     * have no active mapping.
     * @author Melissa Rainboldt
     * @param inserted Sharing Queue rows from the after-insert trigger.
     * @return void
     */
    public static void expandChains(List<Sharing_Queue__c> inserted) {
        List<Sharing_Queue__c> events = new List<Sharing_Queue__c>();
        for (Sharing_Queue__c row : inserted) {
            if (row.Job__c == null && row.Is_Chain_Step__c != true) {
                events.add(row);
            }
        }
        if (events.isEmpty()) return;

        List<Sharing_Queue__c> headsToUpdate = new List<Sharing_Queue__c>();
        List<Sharing_Queue__c> successors = new List<Sharing_Queue__c>();
        Map<Integer, List<Integer>> successorIndexesByHead = new Map<Integer, List<Integer>>();

        for (Sharing_Queue__c eventRow : events) {
            Job__c head = JobCatalogService.headJobFor(
                eventRow.Trigger_Event__c,
                eventRow.Application__c);
            if (head == null) {
                Sharing_Queue__c failed = new Sharing_Queue__c(Id = eventRow.Id);
                applyFailedStatus(
                    failed,
                    missingMappingMessage(eventRow));
                headsToUpdate.add(failed);
                continue;
            }
            List<Job__c> chain = JobCatalogService.walkChain(head);
            Integer headIndex = headsToUpdate.size();
            headsToUpdate.add(new Sharing_Queue__c(
                Id = eventRow.Id,
                Job__c = head.Id,
                Status__c = STATUS_PENDING
            ));
            successorIndexesByHead.put(headIndex, new List<Integer>());

            for (Integer i = 1; i < chain.size(); i++) {
                successors.add(new Sharing_Queue__c(
                    Trigger_Event__c = eventRow.Trigger_Event__c
                   ,  Job__c = chain[i].Id
                   ,  Main_Record_Id__c = eventRow.Main_Record_Id__c
                   ,  Main_Object_Api_Name__c = eventRow.Main_Object_Api_Name__c
                   ,  Source_Record_Id__c = eventRow.Source_Record_Id__c
                   ,  Source_Object_Api_Name__c = eventRow.Source_Object_Api_Name__c
                   ,  Application__c = eventRow.Application__c
                   ,  Status__c = STATUS_BLOCKED
                   ,  Is_Chain_Step__c = true
                   ,  Retry_Count__c = 0
                   ,  Payload__c = eventRow.Payload__c
                ));
                successorIndexesByHead.get(headIndex).add(successors.size() - 1);
            }
        }

        if (!successors.isEmpty()) {
            insert successors;
            List<Sharing_Queue__c> successorLinks = new List<Sharing_Queue__c>();
            for (Integer headIndex : successorIndexesByHead.keySet()) {
                List<Integer> indexes = successorIndexesByHead.get(headIndex);
                if (indexes.isEmpty()) continue;
                headsToUpdate[headIndex].Next_Queue__c = successors[indexes[0]].Id;
                for (Integer i = 0; i < indexes.size() - 1; i++) {
                    successorLinks.add(new Sharing_Queue__c(
                        Id = successors[indexes[i]].Id
                   ,      Next_Queue__c = successors[indexes[i + 1]].Id
                    ));
                }
            }
            if (!successorLinks.isEmpty()) update successorLinks;
        }
        if (!headsToUpdate.isEmpty()) update headsToUpdate;
        kickWorkers();
    }

    /**
     * @description Enqueues the Queueable worker. That worker drains Queueable rows and then starts
     * the Batch worker.
     * @author Melissa Rainboldt
     * @return void
     */
    public static void kickWorkers() {
        SharingQueueQueueable.enqueueOnce();
    }

    /**
     * @description Flex-queue occupancy for a Sharing Queue worker class. Used so
     * enqueueOnce / startIfPending submit at most one job of each type
     * while work remains. excludeJobId is the running job when chaining
     * from Queueable.execute or Batch.finish.
     * @author Melissa Rainboldt
     * @param apexClassName Worker class name, SharingQueueQueueable or SharingQueueBatch.
     * @param excludeJobId Running async job to ignore when counting active workers.
     * @return How many jobs of that class are Holding, Queued, Preparing, or Processing.
     */
    public static Integer activeWorkerCount(String apexClassName, Id excludeJobId) {
        if (apexClassName == QUEUEABLE_WORKER && activeQueueableOverride != null) {
            return activeQueueableOverride;
        }
        if (apexClassName == BATCH_WORKER && activeBatchOverride != null) {
            return activeBatchOverride;
        }
        if (String.isBlank(apexClassName)) {
            return 0;
        }
        if (excludeJobId == null) {
            return [
                SELECT COUNT()
                FROM AsyncApexJob
                WHERE ApexClass.Name = :apexClassName
                AND Status IN :ACTIVE_ASYNC_STATUSES
            ];
        }
        return [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE ApexClass.Name = :apexClassName
            AND Status IN :ACTIVE_ASYNC_STATUSES
            AND Id != :excludeJobId
        ];
    }

    //Claim / complete / fail

    /**
     * @description Moves the rows to Processing, creates a Job Execution for each, and returns
     * both.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param asyncApexJobId AsyncApexJob Id of the worker claiming these rows.
     * @return The queues now in Processing and the Job Execution created for each.
     */
    public static ClaimResult claimQueues(List<Sharing_Queue__c> queues, Id asyncApexJobId) {
        ClaimResult result = new ClaimResult();
        if (queues == null || queues.isEmpty()) return result;
        Datetime now = System.now();
        List<Job_Execution__c> executions = new List<Job_Execution__c>();
        for (Sharing_Queue__c queue : queues) {
            queue.Status__c = STATUS_PROCESSING;
            queue.Last_Attempt_Date__c = now;
            Decimal retry = queue.Retry_Count__c == null ? 0 : queue.Retry_Count__c;
            executions.add(new Job_Execution__c(
                Sharing_Queue__c = queue.Id,
                Job__c = queue.Job__c,
                Status__c = STATUS_PROCESSING,
                Started_At__c = now,
                Retry_Number__c = retry + 1,
                Processor_Kind__c = jobField(queue, 'Processor__c'),
                Async_Apex_Job_Id__c = asyncApexJobId == null ? null : String.valueOf(asyncApexJobId),
                Initiating_App__c = queue.Application__c,
                Process_Name__c = firstPopulated(queue, new List<String>{ 'Name', 'Handler__c' })
            ));
        }
        update queues;
        insert executions;
        result.queues = queues;
        for (Job_Execution__c execution : executions) {
            result.executionsByQueueId.put(execution.Sharing_Queue__c, execution);
        }
        return result;
    }

    /**
     * @description Claims every Pending Batch queue row that can share one child QueryLocator:
     * same catalog Job, same Main, and same Application, up to BATCH_CLAIM_LIMIT.
     * 40 queue rows × 200 children stays under the 10k DML row cap.
     * @author Melissa Rainboldt
     * @param asyncApexJobId AsyncApexJob Id of the worker claiming these rows.
     * @return The claimed batch slice and its job executions. Empty when no compatible Pending row
     * exists.
     */
    public static ClaimResult claimCompatibleBatchSlice(Id asyncApexJobId) {
        ClaimResult empty = new ClaimResult();
        String batchKind = JobCatalogService.PROCESSOR_BATCH;
        List<Sharing_Queue__c> first = [
            SELECT Id
                   , Trigger_Event__c
                   , Job__c
                   , Job__r.Handler__c
                   , Job__r.Processor__c
                   , Job__r.Name
                   , Main_Record_Id__c
                   , Main_Object_Api_Name__c
                   , Source_Record_Id__c
                   , Source_Object_Api_Name__c
                   , Status__c
                   , Next_Queue__c
                   , Retry_Count__c
                   , Payload__c
                   , Records_Processed__c
                   , Application__c
            FROM Sharing_Queue__c
            WHERE Status__c = :STATUS_PENDING
            AND Job__c != null
            AND Job__r.Processor__c = :batchKind
            LIMIT 1
            FOR UPDATE
        ];
        if (first.isEmpty()) return empty;

        String mainId = first[0].Main_Record_Id__c;
        Id catalogJobId = first[0].Job__c;
        String application = first[0].Application__c;
        Integer take = BATCH_CLAIM_LIMIT;
        List<Sharing_Queue__c> slice = [
            SELECT Id
                   , Trigger_Event__c
                   , Job__c
                   , Job__r.Handler__c
                   , Job__r.Processor__c
                   , Job__r.Name
                   , Main_Record_Id__c
                   , Main_Object_Api_Name__c
                   , Source_Record_Id__c
                   , Source_Object_Api_Name__c
                   , Status__c
                   , Next_Queue__c
                   , Retry_Count__c
                   , Payload__c
                   , Records_Processed__c
                   , Application__c
            FROM Sharing_Queue__c
            WHERE Status__c = :STATUS_PENDING
            AND Job__c = :catalogJobId
            AND Main_Record_Id__c = :mainId
            AND Application__c = :application
            LIMIT :take
            FOR UPDATE
        ];
        return claimQueues(slice, asyncApexJobId);
    }

    /**
     * @description Marks the queue rows and job executions completed, stores the share-row count,
     * and activates the next chain step.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param execution Job execution for the queue. Null when one was not created.
     * @param recordsProcessed Share-row count stored on Records Processed.
     * @return void
     */
    public static void markCompleted(
            Sharing_Queue__c queue,
            Job_Execution__c execution,
            Integer recordsProcessed) {
        Map<Id, Job_Execution__c> executions = new Map<Id, Job_Execution__c>();
        if (execution != null) executions.put(queue.Id, execution);
        Map<Id, Integer> processed = new Map<Id, Integer>{ queue.Id => recordsProcessed };
        markCompleted(new List<Sharing_Queue__c>{ queue }, executions, processed);
    }

    /**
     * @description Marks the queue rows and job executions completed, stores the share-row count,
     * and activates the next chain step.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param recordsProcessedByQueueId Share-row counts keyed by Sharing Queue Id.
     * @return void
     */
    public static void markCompleted(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            Map<Id, Integer> recordsProcessedByQueueId) {
        markCompleted(queues, executionsByQueueId, recordsProcessedByQueueId, null, true);
    }

    /**
     * @description Marks the queue rows and job executions completed, stores the share-row count,
     * and activates the next chain step.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param recordsProcessedByQueueId Share-row counts keyed by Sharing Queue Id.
     * @param usage Governor snapshot to stamp. Null skips stamping unless captureIfNull is true.
     * @return void
     */
    public static void markCompleted(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            Map<Id, Integer> recordsProcessedByQueueId,
            VolumeLimits usage) {
        markCompleted(queues, executionsByQueueId, recordsProcessedByQueueId, usage, false);
    }

    /**
     * @description Marks the queue rows and job executions completed, stores the share-row count,
     * and activates the next chain step.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param recordsProcessedByQueueId Share-row counts keyed by Sharing Queue Id.
     * @param usage Governor snapshot to stamp. Null skips stamping unless captureIfNull is true.
     * @param captureIfNull When true and usage is null, stamp the limits of the current
     * transaction.
     * @return void
     */
    private static void markCompleted(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            Map<Id, Integer> recordsProcessedByQueueId,
            VolumeLimits usage,
            Boolean captureIfNull) {
        if (queues == null || queues.isEmpty()) return;
        Datetime now = System.now();
        List<Job_Execution__c> executions = new List<Job_Execution__c>();
        for (Sharing_Queue__c queue : queues) {
            Integer processed = recordsProcessedByQueueId == null
                ? null
                : recordsProcessedByQueueId.get(queue.Id);
            queue.Status__c = STATUS_COMPLETED;
            queue.Processed_Date__c = now;
            queue.Records_Processed__c = processed;
            queue.Last_Error__c = null;
            Job_Execution__c execution = executionsByQueueId == null
                ? null
                : executionsByQueueId.get(queue.Id);
            if (execution != null) {
                execution.Status__c = STATUS_COMPLETED;
                execution.Completed_At__c = now;
                execution.Records_Processed__c = processed;
                execution.Error_Message__c = null;
                executions.add(execution);
            }
        }
        stampGovernorUsage(executions, usage, captureIfNull);
        update queues;
        if (!executions.isEmpty()) update executions;
        activateNextQueues(queues);
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param execution Job execution for the queue. Null when one was not created.
     * @param e Exception that failed the queue. Null is stored as Unknown error.
     * @param recordsProcessed Share-row count stored on Records Processed.
     * @return void
     */
    public static void markFailed(
            Sharing_Queue__c queue,
            Job_Execution__c execution,
            Exception e,
            Integer recordsProcessed) {
        String message = e == null ? 'Unknown error' : (e.getMessage() + '\n' + e.getStackTraceString());
        markFailed(queue, execution, message, recordsProcessed);
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param execution Job execution for the queue. Null when one was not created.
     * @param message Failure text. The queue stays Pending until the retry limit, then becomes
     * Failed.
     * @param recordsProcessed Share-row count stored on Records Processed.
     * @return void
     */
    public static void markFailed(
            Sharing_Queue__c queue,
            Job_Execution__c execution,
            String message,
            Integer recordsProcessed) {
        Map<Id, Job_Execution__c> executions = new Map<Id, Job_Execution__c>();
        if (execution != null) executions.put(queue.Id, execution);
        markFailed(
            new List<Sharing_Queue__c>{ queue },
            executions,
            new Map<Id, String>{ queue.Id => message },
            new Map<Id, Integer>{ queue.Id => recordsProcessed });
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param message Failure text. The queue stays Pending until the retry limit, then becomes
     * Failed.
     * @param recordsProcessed Share-row count stored on Records Processed.
     * @return void
     */
    public static void markFailed(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            String message,
            Integer recordsProcessed) {
        markFailed(queues, executionsByQueueId, message, recordsProcessed, null, true);
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param message Failure text. The queue stays Pending until the retry limit, then becomes
     * Failed.
     * @param recordsProcessed Share-row count stored on Records Processed.
     * @param usage Governor snapshot to stamp. Null skips stamping unless captureIfNull is true.
     * @return void
     */
    public static void markFailed(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            String message,
            Integer recordsProcessed,
            VolumeLimits usage) {
        markFailed(queues, executionsByQueueId, message, recordsProcessed, usage, false);
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param message Failure text. The queue stays Pending until the retry limit, then becomes
     * Failed.
     * @param recordsProcessed Share-row count stored on Records Processed.
     * @param usage Governor snapshot to stamp. Null skips stamping unless captureIfNull is true.
     * @param captureIfNull When true and usage is null, stamp the limits of the current
     * transaction.
     * @return void
     */
    private static void markFailed(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            String message,
            Integer recordsProcessed,
            VolumeLimits usage,
            Boolean captureIfNull) {
        if (queues == null || queues.isEmpty()) return;
        Map<Id, String> errorByQueueId = new Map<Id, String>();
        Map<Id, Integer> recordsProcessedByQueueId = new Map<Id, Integer>();
        for (Sharing_Queue__c queue : queues) {
            errorByQueueId.put(queue.Id, message);
            recordsProcessedByQueueId.put(queue.Id, recordsProcessed);
        }
        markFailed(
            queues,
            executionsByQueueId,
            errorByQueueId,
            recordsProcessedByQueueId,
            usage,
            captureIfNull);
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param errorByQueueId Failure text keyed by Sharing Queue Id.
     * @param recordsProcessedByQueueId Share-row counts keyed by Sharing Queue Id.
     * @return void
     */
    public static void markFailed(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            Map<Id, String> errorByQueueId,
            Map<Id, Integer> recordsProcessedByQueueId) {
        markFailed(
            queues,
            executionsByQueueId,
            errorByQueueId,
            recordsProcessedByQueueId,
            null,
            true);
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param errorByQueueId Failure text keyed by Sharing Queue Id.
     * @param recordsProcessedByQueueId Share-row counts keyed by Sharing Queue Id.
     * @param usage Governor snapshot to stamp. Null skips stamping unless captureIfNull is true.
     * @return void
     */
    public static void markFailed(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            Map<Id, String> errorByQueueId,
            Map<Id, Integer> recordsProcessedByQueueId,
            VolumeLimits usage) {
        markFailed(
            queues,
            executionsByQueueId,
            errorByQueueId,
            recordsProcessedByQueueId,
            usage,
            false);
    }

    /**
     * @description Records the failure on the queue and job execution. Below the retry limit the
     * queue returns to Pending; at the limit it is Failed.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param executionsByQueueId Job executions keyed by Sharing Queue Id.
     * @param errorByQueueId Failure text keyed by Sharing Queue Id.
     * @param recordsProcessedByQueueId Share-row counts keyed by Sharing Queue Id.
     * @param usage Governor snapshot to stamp. Null skips stamping unless captureIfNull is true.
     * @param captureIfNull When true and usage is null, stamp the limits of the current
     * transaction.
     * @return void
     */
    private static void markFailed(
            List<Sharing_Queue__c> queues,
            Map<Id, Job_Execution__c> executionsByQueueId,
            Map<Id, String> errorByQueueId,
            Map<Id, Integer> recordsProcessedByQueueId,
            VolumeLimits usage,
            Boolean captureIfNull) {
        if (queues == null || queues.isEmpty()) return;
        Datetime now = System.now();
        List<Job_Execution__c> executions = new List<Job_Execution__c>();
        for (Sharing_Queue__c queue : queues) {
            Decimal retries = queue.Retry_Count__c == null ? 0 : queue.Retry_Count__c;
            retries += 1;
            queue.Retry_Count__c = retries;
            Integer processed = recordsProcessedByQueueId == null
                ? null
                : recordsProcessedByQueueId.get(queue.Id);
            queue.Records_Processed__c = processed;
            String message = errorByQueueId == null ? null : errorByQueueId.get(queue.Id);
            if (retries < MAX_RETRIES) {
                queue.Status__c = STATUS_PENDING;
                queue.Last_Error__c = truncateError(message);
            } else {
                applyFailedStatus(queue, message);
            }
            Job_Execution__c execution = executionsByQueueId == null
                ? null
                : executionsByQueueId.get(queue.Id);
            if (execution != null) {
                execution.Status__c = STATUS_FAILED;
                execution.Completed_At__c = now;
                execution.Records_Processed__c = processed;
                execution.Error_Message__c = truncateError(message);
                executions.add(execution);
            }
        }
        stampGovernorUsage(executions, usage, captureIfNull);
        update queues;
        if (!executions.isEmpty()) update executions;
    }

    /**
     * @description Copies governor used and limit fields onto the job executions.
     * @author Melissa Rainboldt
     * @param executions Job execution rows to stamp.
     * @param usage Governor snapshot to stamp. Null skips stamping unless captureIfNull is true.
     * @param captureIfNull When true and usage is null, stamp the limits of the current
     * transaction.
     * @return void
     */
    private static void stampGovernorUsage(
            List<Job_Execution__c> executions,
            VolumeLimits usage,
            Boolean captureIfNull) {
        if (executions == null || executions.isEmpty()) return;
        VolumeLimits snap = usage;
        if (snap == null && captureIfNull) snap = VolumeLimits.capture();
        if (snap == null) return;
        for (Job_Execution__c execution : executions) {
            snap.applyTo(execution);
        }
    }

    /**
     * @description Saves the payload cursor and records-processed count on one queue row.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param payload Queue payload carrying principal, access, related objects, and cursor.
     * @param recordsProcessed Share-row count recorded for the queue.
     * @return void
     */
    public static void persistCursor(Sharing_Queue__c queue, Payload payload, Integer recordsProcessed) {
        persistCursors(new List<Sharing_Queue__c>{ queue }, payload, recordsProcessed);
    }

    /**
     * @description Saves one payload cursor and records-processed count on each queue row.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param payload Queue payload carrying principal, access, related objects, and cursor.
     * @param recordsProcessed Share-row count recorded for the queue.
     * @return void
     */
    public static void persistCursors(
            List<Sharing_Queue__c> queues,
            Payload payload,
            Integer recordsProcessed) {
        if (queues == null || queues.isEmpty()) return;
        String json = payload.toJson();
        for (Sharing_Queue__c queue : queues) {
            queue.Payload__c = json;
            queue.Records_Processed__c = recordsProcessed;
        }
        update queues;
    }

    /**
     * @description Returns Processing rows older than two hours to Pending, or Failed when retries
     * are exhausted.
     * @author Melissa Rainboldt
     * @return The number of stuck Processing rows that were reset or failed.
     */
    public static Integer unstickClaims() {
        Datetime cutoff = System.now().addHours(-2);
        List<Sharing_Queue__c> stuck = [SELECT Id
                                            , Status__c
                                            , Retry_Count__c
                                            , Last_Error__c
                                            , Processed_Date__c
                                            , Application__c
                                        FROM Sharing_Queue__c
                                        WHERE Status__c = :STATUS_PROCESSING
                                            AND Last_Attempt_Date__c < :cutoff
                                        LIMIT 200
                                        ];
        if (stuck.isEmpty()) return 0;
        List<Job_Execution__c> openExecs = [
            SELECT Id, Sharing_Queue__c
            FROM Job_Execution__c
            WHERE Sharing_Queue__c IN :stuck
            AND Status__c = :STATUS_PROCESSING
        ];
        for (Sharing_Queue__c queue : stuck) {
            Decimal retries = queue.Retry_Count__c == null ? 0 : queue.Retry_Count__c;
            queue.Last_Error__c = truncateError('Stuck in Processing (LastAttemptDate older than 2 hours)');
            if (retries >= MAX_RETRIES) {
                applyFailedStatus(queue, STUCK_MESSAGE);
            } else {
                queue.Status__c = STATUS_PENDING;
            }
        }
        update stuck;
        for (Job_Execution__c execution : openExecs) {
            execution.Status__c = STATUS_FAILED;
            execution.Completed_At__c = System.now();
            execution.Error_Message__c = 'Stuck in Processing (LastAttemptDate older than 2 hours)';
        }
        if (!openExecs.isEmpty()) update openExecs;
        return stuck.size();
    }

    /**
     * @description Cancels related and fan-out rows that a broader job already covers, and promotes
     * a main to reconcile when the thresholds say so.
     * @author Melissa Rainboldt
     * @return The number of mains whose open work was cancelled or promoted.
     */
    public static Integer compactOpenWork() {
        return compactOpenWork(null);
    }

    /**
     * @description Cancels related and fan-out rows that a broader job already covers, and promotes
     * a main to reconcile when the thresholds say so.
     * @author Melissa Rainboldt
     * @param mainIds Main Ids to compact. Null compacts every open main once in this transaction.
     * @return The number of mains whose open work was cancelled or promoted.
     */
    public static Integer compactOpenWork(Set<String> mainIds) {
        if (mainIds == null) {
            if (compactedThisTx) return 0;
            compactedThisTx = true;
        }
        List<Sharing_Queue__c> openRows = queryCompactableRows(mainIds);
        if (openRows.isEmpty()) return 0;

        Map<String, List<Sharing_Queue__c>> byGroup = new Map<String, List<Sharing_Queue__c>>();
        for (Sharing_Queue__c row : openRows) {
            if (String.isBlank(row.Main_Record_Id__c) || String.isBlank(row.Application__c)) continue;
            String groupKey = compactGroupKey(row.Main_Record_Id__c, row.Application__c);
            if (!byGroup.containsKey(groupKey)) {
                byGroup.put(groupKey, new List<Sharing_Queue__c>());
            }
            byGroup.get(groupKey).add(row);
        }

        List<Sharing_Queue__c> toCancel = new List<Sharing_Queue__c>();
        List<Sharing_Queue__c> toUnblock = new List<Sharing_Queue__c>();
        Map<String, Set<Id>> mainsToReconcileByApp = new Map<String, Set<Id>>();
        Integer decisions = 0;

        for (String groupKey : byGroup.keySet()) {
            List<Sharing_Queue__c> groupRows = byGroup.get(groupKey);
            String mainId = groupRows[0].Main_Record_Id__c;
            String application = groupRows[0].Application__c;
            List<Sharing_Queue__c> related = new List<Sharing_Queue__c>();
            List<Sharing_Queue__c> fanout = new List<Sharing_Queue__c>();
            List<Sharing_Queue__c> reconcile = new List<Sharing_Queue__c>();
            for (Sharing_Queue__c row : groupRows) {
                String handlerName = row.Job__r == null ? null : row.Job__r.Handler__c;
                SharingQueueHandler handler = SharingQueueHandlerRegistry.tryResolve(handlerName);
                if (handler == null) continue;
                if (handler.isRelatedRecordJob()) {
                    related.add(row);
                } else if (handler.isFanoutJob()) {
                    fanout.add(row);
                } else if (handler.isReconcileJob()) {
                    reconcile.add(row);
                }
            }

            if (!reconcile.isEmpty()) {
                toCancel.addAll(related);
                toCancel.addAll(fanout);
                for (Sharing_Queue__c row : reconcile) {
                    if (row.Status__c == STATUS_BLOCKED) toUnblock.add(row);
                }
                if (!related.isEmpty() || !fanout.isEmpty()) decisions++;
                continue;
            }

            List<Sharing_Queue__c> pendingFanout = new List<Sharing_Queue__c>();
            for (Sharing_Queue__c row : fanout) {
                if (row.Status__c == STATUS_PENDING) pendingFanout.add(row);
            }

            if (fanoutCoversTeam(mainId, groupRows[0], pendingFanout) && !related.isEmpty()) {
                toCancel.addAll(related);
                decisions++;
                continue;
            }

            if (shouldPromoteToReconcile(related.size(), fanout.size())) {
                if (!mainsToReconcileByApp.containsKey(application)) {
                    mainsToReconcileByApp.put(application, new Set<Id>());
                }
                mainsToReconcileByApp.get(application).add(toId(mainId));
                toCancel.addAll(related);
                toCancel.addAll(fanout);
                decisions++;
            }
        }

        for (String application : mainsToReconcileByApp.keySet()) {
            enqueueReconcileForMains(
                mainsToReconcileByApp.get(application),
                JobCatalogService.EVENT_RECONCILE_SWEEP,
                application);
        }
        if (!toUnblock.isEmpty()) {
            for (Sharing_Queue__c row : toUnblock) {
                row.Status__c = STATUS_PENDING;
            }
            update toUnblock;
        }
        if (!toCancel.isEmpty()) {
            cancelQueues(toCancel, 'Subsumed by a broader job for the same Main');
        }
        return decisions;
    }

    /**
     * @description Returns whether open related and fan-out counts meet a compaction threshold. A
     * threshold of 0 disables that rule.
     * @author Melissa Rainboldt
     * @param relatedCount Open related-record queue rows on the main.
     * @param fanoutCount Open fan-out queue rows on the main.
     * @return True when a configured threshold is enabled and the counts meet it.
     */
    @TestVisible
    static Boolean shouldPromoteToReconcile(Integer relatedCount, Integer fanoutCount) {
        if (relatedCount == null || fanoutCount == null) return false;
        Integer openWork = relatedCount + fanoutCount;
        Integer openThreshold = SharingQueueSettings.openWorkThreshold();
        if (openThreshold > 0 && openWork >= openThreshold) return true;
        if (relatedCount == 0 || fanoutCount == 0) return false;
        Integer relatedBunch = SharingQueueSettings.relatedBunchThreshold();
        Integer fanoutSome = SharingQueueSettings.fanoutSomeThreshold();
        Integer mixedProduct = SharingQueueSettings.mixedProductThreshold();
        return (relatedBunch > 0 && relatedCount >= relatedBunch)
            || (fanoutSome > 0 && fanoutCount >= fanoutSome)
            || (mixedProduct > 0 && (relatedCount * fanoutCount) >= mixedProduct);
    }

    /**
     * @description Returns whether the pending fan-out rows already include every active team
     * member principal on the main.
     * @author Melissa Rainboldt
     * @param mainId Main record Id.
     * @param sample Queue row used to resolve the application.
     * @param fanout Pending fan-out queue rows for the main.
     * @return True when every active team member principal is already in the fan-out set.
     */
    private static Boolean fanoutCoversTeam(
            String mainId,
            Sharing_Queue__c sample,
            List<Sharing_Queue__c> fanout) {
        if (fanout.isEmpty() || sample == null) return false;
        Set<Id> fanoutUsers = new Set<Id>();
        for (Sharing_Queue__c row : fanout) {
            Payload payload = parsePayload(row.Payload__c);
            Id userId = toId(payload.userOrGroupId);
            if (userId != null) fanoutUsers.add(userId);
        }
        if (fanoutUsers.isEmpty()) return false;
        try {
            SharingConfigService cfg = SharingConfigService.getInstance(sample.Application__c);
            Id parentId = toId(mainId);
            if (parentId == null) return false;
            List<SObject> teamMembers = TeamMemberSharingService.queryTeamMembers(
                new Set<Id>{ parentId }, cfg);
            if (teamMembers.isEmpty()) return false;
            Set<Id> tmUsers = new Set<Id>();
            for (SObject tm : teamMembers) {
                Id principalId = TeamMemberSharingService.userOrGroupId(tm, cfg.teamMemberConfig);
                if (principalId != null) tmUsers.add(principalId);
            }
            return !tmUsers.isEmpty() && fanoutUsers.containsAll(tmUsers);
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * @description Loads Pending and Blocked rows compaction is allowed to cancel or promote.
     * @author Melissa Rainboldt
     * @param mainIds Main record Ids.
     * @return Pending and Blocked rows compaction may cancel or promote.
     */
    private static List<Sharing_Queue__c> queryCompactableRows(Set<String> mainIds) {
        List<String> compactStatuses = new List<String>{ STATUS_PENDING, STATUS_BLOCKED };
        if (mainIds == null || mainIds.isEmpty()) {
            return [SELECT Id
                        , Main_Record_Id__c
                        , Main_Object_Api_Name__c
                        , Application__c
                        , Status__c
                        , Payload__c
                        , Job__c
                        , Job__r.Handler__c
                FROM Sharing_Queue__c
                WHERE Status__c IN :compactStatuses
                AND Job__c != null
                LIMIT 2000
            ];
        }
        return [SELECT Id
                    , Main_Record_Id__c
                    , Main_Object_Api_Name__c
                    , Application__c
                    , Status__c
                    , Payload__c
                    , Job__c
                    , Job__r.Handler__c
            FROM Sharing_Queue__c
            WHERE Status__c IN :compactStatuses
            AND Job__c != null
            AND Main_Record_Id__c IN :mainIds
            LIMIT 2000
        ];
    }

    /**
     * @description Sets the rows to Cancelled and stores the reason on Last Error.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @param reason Text written to Last Error.
     * @return void
     */
    private static void cancelQueues(List<Sharing_Queue__c> rows, String reason) {
        for (Sharing_Queue__c row : rows) {
            row.Status__c = STATUS_CANCELLED;
            row.Processed_Date__c = null;
            row.Last_Error__c = truncateError(reason);
        }
        update rows;
    }

    /**
     * @description Sets the completed row's successor to Pending when it is still waiting.
     * @author Melissa Rainboldt
     * @param completed Queue row or rows that just completed.
     * @return void
     */
    private static void activateNextQueue(Sharing_Queue__c completed) {
        if (completed == null) return;
        activateNextQueues(new List<Sharing_Queue__c>{ completed });
    }

    /**
     * @description Sets each completed row's successor to Pending when it is still waiting.
     * @author Melissa Rainboldt
     * @param completed Queue row or rows that just completed.
     * @return void
     */
    private static void activateNextQueues(List<Sharing_Queue__c> completed) {
        if (completed == null || completed.isEmpty()) return;
        Set<Id> nextIds = new Set<Id>();
        for (Sharing_Queue__c queue : completed) {
            if (queue != null && queue.Next_Queue__c != null) nextIds.add(queue.Next_Queue__c);
        }
        if (nextIds.isEmpty()) return;
        List<Sharing_Queue__c> toActivate = new List<Sharing_Queue__c>();
        for (Sharing_Queue__c nextRow : [
            SELECT Id, Status__c
            FROM Sharing_Queue__c
            WHERE Id IN :nextIds
        ]) {
            if (nextRow.Status__c == STATUS_COMPLETED
                    || nextRow.Status__c == STATUS_FAILED
                    || nextRow.Status__c == STATUS_CANCELLED
                    || nextRow.Status__c == STATUS_PROCESSING) {
                continue;
            }
            nextRow.Status__c = STATUS_PENDING;
            toActivate.add(nextRow);
        }
        if (!toActivate.isEmpty()) update toActivate;
    }

    //Handlers

    /**
     * @description Runs the row's Queueable handler and returns the share-row count.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return The number of share rows the handler wrote.
     */
    public static Integer processCheapQueue(Sharing_Queue__c queue) {
        String handler = queue.Job__r == null ? null : queue.Job__r.Handler__c;
        Integer cpuBefore = Limits.getCpuTime();
        SharingQueueHandler resolved = SharingQueueHandlerRegistry.resolve(handler);
        String childObject = resolved.isRelatedRecordJob()
            ? relatedChildObjectApiName(queue)
            : null;
        debugJobExecution(queue, 'start', cpuBefore, null, childObject);
        Integer processed = resolved.process(queue);
        debugJobExecution(queue, 'done', cpuBefore, processed, childObject);
        return processed;
    }

    /**
     * @description Drain claimed Queueable rows: collect ShareMainDirect-style shares into
     * one insert, then complete/fail with two updates (queues + executions).
     * @author Melissa Rainboldt
     * @param claimed Queues and job executions claimed for this drain.
     * @return void
     */
    public static void processClaimedCheapQueues(ClaimResult claimed) {
        if (claimed == null || claimed.queues == null || claimed.queues.isEmpty()) return;

        List<Sharing_Queue__c> succeeded = new List<Sharing_Queue__c>();
        List<Sharing_Queue__c> failed = new List<Sharing_Queue__c>();
        Map<Id, Integer> processedByQueue = new Map<Id, Integer>();
        Map<Id, String> errorByQueue = new Map<Id, String>();
        List<SObject> pendingShares = new List<SObject>();
        Map<String, Set<Id>> queueIdsByShareKey = new Map<String, Set<Id>>();
        Set<Id> bulkQueueIds = new Set<Id>();

        List<Sharing_Queue__c> relatedQueues = new List<Sharing_Queue__c>();
        List<Sharing_Queue__c> mainDirectQueues = new List<Sharing_Queue__c>();
        for (Sharing_Queue__c queue : claimed.queues) {
            String handlerName = queue.Job__r == null ? null : queue.Job__r.Handler__c;
            try {
                SharingQueueHandler handler = SharingQueueHandlerRegistry.resolve(handlerName);
                if (handler.collectsShares() && handler.isRelatedRecordJob()) {
                    relatedQueues.add(queue);
                    bulkQueueIds.add(queue.Id);
                } else if (handler.collectsShares() && handler.isShareMainDirectJob()) {
                    mainDirectQueues.add(queue);
                    bulkQueueIds.add(queue.Id);
                } else if (handler.collectsShares()) {
                    Integer cpuBefore = Limits.getCpuTime();
                    String childObject = handler.isRelatedRecordJob()
                        ? relatedChildObjectApiName(queue)
                        : null;
                    debugJobExecution(queue, 'start', cpuBefore, null, childObject);
                    List<SObject> shares = handler.collectShares(queue);
                    Integer count = 0;
                    if (shares != null) {
                        for (SObject share : shares) {
                            if (share == null) continue;
                            pendingShares.add(share);
                            String key = TeamMemberSharingService.shareRowKey(share);
                            if (String.isNotBlank(key)) {
                                if (!queueIdsByShareKey.containsKey(key)) {
                                    queueIdsByShareKey.put(key, new Set<Id>());
                                }
                                queueIdsByShareKey.get(key).add(queue.Id);
                            }
                            count++;
                        }
                    }
                    debugJobExecution(queue, 'done', cpuBefore, count, childObject);
                    processedByQueue.put(queue.Id, count);
                    bulkQueueIds.add(queue.Id);
                    succeeded.add(queue);
                } else {
                    Integer processed = processCheapQueue(queue);
                    processedByQueue.put(queue.Id, processed);
                    succeeded.add(queue);
                }
            } catch (Exception e) {
                failed.add(queue);
                processedByQueue.put(queue.Id, 0);
                errorByQueue.put(
                    queue.Id,
                    e.getMessage() + '\n' + e.getStackTraceString());
            }
        }

        collectRelatedRecordShares(
            relatedQueues,
            pendingShares,
            queueIdsByShareKey,
            processedByQueue,
            succeeded,
            failed,
            errorByQueue);

        collectMainDirectShares(
            mainDirectQueues,
            pendingShares,
            queueIdsByShareKey,
            processedByQueue,
            succeeded,
            failed,
            errorByQueue);

        if (!pendingShares.isEmpty()) {
            try {
                TeamMemberSharingService.ShareDmlOutcome outcome =
                    TeamMemberSharingService.insertSharesPartial(pendingShares);
                if (outcome.hasFatal()) {
                    Set<Id> failIds = new Set<Id>();
                    for (String key : outcome.fatalByShareKey.keySet()) {
                        Set<Id> queueIds = queueIdsByShareKey.get(key);
                        if (queueIds == null) continue;
                        String message = outcome.fatalByShareKey.get(key);
                        for (Id queueId : queueIds) {
                            failIds.add(queueId);
                            errorByQueue.put(queueId, message);
                        }
                    }
                    if (failIds.isEmpty()) {
                        String joined = String.join(outcome.fatalMessages, '; ');
                        for (Id queueId : bulkQueueIds) {
                            failIds.add(queueId);
                            errorByQueue.put(queueId, joined);
                        }
                    }
                    List<Sharing_Queue__c> kept = new List<Sharing_Queue__c>();
                    for (Sharing_Queue__c queue : succeeded) {
                        if (failIds.contains(queue.Id)) {
                            failed.add(queue);
                        } else {
                            kept.add(queue);
                        }
                    }
                    succeeded = kept;
                }
            } catch (Exception e) {
                String message = e.getMessage() + '\n' + e.getStackTraceString();
                List<Sharing_Queue__c> kept = new List<Sharing_Queue__c>();
                for (Sharing_Queue__c queue : succeeded) {
                    if (bulkQueueIds.contains(queue.Id)) {
                        failed.add(queue);
                        errorByQueue.put(queue.Id, message);
                    } else {
                        kept.add(queue);
                    }
                }
                succeeded = kept;
            }
        }

        markCompleted(succeeded, claimed.executionsByQueueId, processedByQueue);
        markFailed(failed, claimed.executionsByQueueId, errorByQueue, processedByQueue);
    }

    /**
     * @description One query per child object per Application, then one share list for the
     * drain's insertSharesPartial. Maps each share back to queue rows by child Id.
     * @author Melissa Rainboldt
     * @param relatedQueues Related-record queue rows whose shares are collected together.
     * @param pendingShares Share sObjects collected for a single insert.
     * @param queueIdsByShareKey Sharing Queue Ids that produced each share key.
     * @param processedByQueue Share-row counts keyed by Sharing Queue Id, updated as shares are collected.
     * @param succeeded Queue rows collected or processed without an error so far.
     * @param failed Queue rows that failed while collecting shares.
     * @param errorByQueue Failure text keyed by Sharing Queue Id.
     * @return void
     */
    private static void collectRelatedRecordShares(
            List<Sharing_Queue__c> relatedQueues,
            List<SObject> pendingShares,
            Map<String, Set<Id>> queueIdsByShareKey,
            Map<Id, Integer> processedByQueue,
            List<Sharing_Queue__c> succeeded,
            List<Sharing_Queue__c> failed,
            Map<Id, String> errorByQueue) {
        if (relatedQueues == null || relatedQueues.isEmpty()) return;

        Map<String, List<Sharing_Queue__c>> byApp = new Map<String, List<Sharing_Queue__c>>();
        for (Sharing_Queue__c queue : relatedQueues) {
            String app = String.isBlank(queue.Application__c) ? '' : queue.Application__c;
            if (!byApp.containsKey(app)) {
                byApp.put(app, new List<Sharing_Queue__c>());
            }
            byApp.get(app).add(queue);
        }
        for (String app : byApp.keySet()) {
            try {
                collectRelatedRecordSharesForApp(
                    app,
                    byApp.get(app),
                    pendingShares,
                    queueIdsByShareKey,
                    processedByQueue,
                    succeeded);
            } catch (Exception e) {
                String message = e.getMessage() + '\n' + e.getStackTraceString();
                for (Sharing_Queue__c queue : byApp.get(app)) {
                    failed.add(queue);
                    processedByQueue.put(queue.Id, 0);
                    errorByQueue.put(queue.Id, message);
                }
            }
        }
    }

    /**
     * @description Queries the related children for one application and appends their shares.
     * @author Melissa Rainboldt
     * @param application Application API name that selects the catalog and sharing configuration.
     * @param queues Sharing Queue rows in this unit of work.
     * @param pendingShares Share sObjects collected for a single insert.
     * @param queueIdsByShareKey Sharing Queue Ids that produced each share key.
     * @param processedByQueue Share-row counts keyed by Sharing Queue Id, updated as shares are collected.
     * @param succeeded Queue rows collected or processed without an error so far.
     * @return void
     */
    private static void collectRelatedRecordSharesForApp(
            String application,
            List<Sharing_Queue__c> queues,
            List<SObject> pendingShares,
            Map<String, Set<Id>> queueIdsByShareKey,
            Map<Id, Integer> processedByQueue,
            List<Sharing_Queue__c> succeeded) {
        SharingConfigService cfg = SharingConfigService.getInstance(application);
        Map<String, Set<Id>> idsByObject = new Map<String, Set<Id>>();
        Map<String, String> apiNameByKey = new Map<String, String>();
        Map<Id, Set<Id>> queuesByChildId = new Map<Id, Set<Id>>();
        for (Sharing_Queue__c queue : queues) {
            Integer cpuBefore = Limits.getCpuTime();
            String objectApiName = relatedChildObjectApiName(queue);
            debugJobExecution(queue, 'start', cpuBefore, null, objectApiName);
            Id sourceId = toId(queue.Source_Record_Id__c);
            if (String.isBlank(objectApiName) || sourceId == null) {
                processedByQueue.put(queue.Id, 0);
                succeeded.add(queue);
                debugJobExecution(queue, 'done', cpuBefore, 0, objectApiName);
                continue;
            }
            String objKey = objectApiName.toLowerCase();
            if (!idsByObject.containsKey(objKey)) {
                idsByObject.put(objKey, new Set<Id>());
                apiNameByKey.put(objKey, objectApiName);
            }
            idsByObject.get(objKey).add(sourceId);
            if (!queuesByChildId.containsKey(sourceId)) {
                queuesByChildId.put(sourceId, new Set<Id>());
            }
            queuesByChildId.get(sourceId).add(queue.Id);
            processedByQueue.put(queue.Id, 0);
            succeeded.add(queue);
            debugJobExecution(queue, 'done', cpuBefore, null, objectApiName);
        }

        Map<String, List<SObject>> recordsByObject = new Map<String, List<SObject>>();
        for (String objKey : idsByObject.keySet()) {
            String apiName = apiNameByKey.get(objKey);
            recordsByObject.put(
                apiName,
                cfg.queryRelatedRecords(apiName, idsByObject.get(objKey)));
        }

        List<SObject> shares = TeamMemberSharingService.buildSharesForNewChildRecords(
            recordsByObject, application);
        Map<Id, Integer> shareCountByChild = new Map<Id, Integer>();
        if (shares != null) {
            for (SObject share : shares) {
                if (share == null) continue;
                pendingShares.add(share);
                Id childId = (Id) share.get('ParentId');
                String key = TeamMemberSharingService.shareRowKey(share);
                Set<Id> queueIds = childId == null ? null : queuesByChildId.get(childId);
                if (queueIds != null && String.isNotBlank(key)) {
                    if (!queueIdsByShareKey.containsKey(key)) {
                        queueIdsByShareKey.put(key, new Set<Id>());
                    }
                    queueIdsByShareKey.get(key).addAll(queueIds);
                }
                if (childId != null) {
                    Integer soFar = shareCountByChild.containsKey(childId)
                        ? shareCountByChild.get(childId)
                        : 0;
                    shareCountByChild.put(childId, soFar + 1);
                }
            }
        }
        for (Sharing_Queue__c queue : queues) {
            Id sourceId = toId(queue.Source_Record_Id__c);
            Integer count = sourceId == null ? 0 : shareCountByChild.get(sourceId);
            processedByQueue.put(queue.Id, count == null ? 0 : count);
        }
    }

    /**
     * @description One Team Member query per Application (by Source Id, no Active filter),
     * then Main shares in memory. Payload fills principal/access when the TM
     * row is missing. One parent-axis query only if access is still unresolved.
     * @author Melissa Rainboldt
     * @param mainDirectQueues ShareMainDirect queue rows whose shares are collected together.
     * @param pendingShares Share sObjects collected for a single insert.
     * @param queueIdsByShareKey Sharing Queue Ids that produced each share key.
     * @param processedByQueue Share-row counts keyed by Sharing Queue Id, updated as shares are collected.
     * @param succeeded Queue rows collected or processed without an error so far.
     * @param failed Queue rows that failed while collecting shares.
     * @param errorByQueue Failure text keyed by Sharing Queue Id.
     * @return void
     */
    private static void collectMainDirectShares(
            List<Sharing_Queue__c> mainDirectQueues,
            List<SObject> pendingShares,
            Map<String, Set<Id>> queueIdsByShareKey,
            Map<Id, Integer> processedByQueue,
            List<Sharing_Queue__c> succeeded,
            List<Sharing_Queue__c> failed,
            Map<Id, String> errorByQueue) {
        if (mainDirectQueues == null || mainDirectQueues.isEmpty()) return;

        Map<String, List<Sharing_Queue__c>> byApp = new Map<String, List<Sharing_Queue__c>>();
        for (Sharing_Queue__c queue : mainDirectQueues) {
            String app = String.isBlank(queue.Application__c) ? '' : queue.Application__c;
            if (!byApp.containsKey(app)) {
                byApp.put(app, new List<Sharing_Queue__c>());
            }
            byApp.get(app).add(queue);
        }
        for (String app : byApp.keySet()) {
            try {
                collectMainDirectSharesForApp(
                    app,
                    byApp.get(app),
                    pendingShares,
                    queueIdsByShareKey,
                    processedByQueue,
                    succeeded);
            } catch (Exception e) {
                String message = e.getMessage() + '\n' + e.getStackTraceString();
                for (Sharing_Queue__c queue : byApp.get(app)) {
                    failed.add(queue);
                    processedByQueue.put(queue.Id, 0);
                    errorByQueue.put(queue.Id, message);
                }
            }
        }
    }

    /**
     * @description Loads team members for one application and appends the main shares.
     * @author Melissa Rainboldt
     * @param application Application API name that selects the catalog and sharing configuration.
     * @param queues Sharing Queue rows in this unit of work.
     * @param pendingShares Share sObjects collected for a single insert.
     * @param queueIdsByShareKey Sharing Queue Ids that produced each share key.
     * @param processedByQueue Share-row counts keyed by Sharing Queue Id, updated as shares are collected.
     * @param succeeded Queue rows collected or processed without an error so far.
     * @return void
     */
    private static void collectMainDirectSharesForApp(
            String application,
            List<Sharing_Queue__c> queues,
            List<SObject> pendingShares,
            Map<String, Set<Id>> queueIdsByShareKey,
            Map<Id, Integer> processedByQueue,
            List<Sharing_Queue__c> succeeded) {
        SharingConfigService cfg = SharingConfigService.getInstance(application);
        Set<Id> sourceIds = new Set<Id>();
        for (Sharing_Queue__c queue : queues) {
            Id sourceId = toId(queue.Source_Record_Id__c);
            if (sourceId != null) sourceIds.add(sourceId);
        }
        Map<Id, SObject> teamMembersById =
            TeamMemberSharingService.queryTeamMembersByIds(sourceIds, cfg);

        Map<Id, List<SObject>> noFallbackQuery = new Map<Id, List<SObject>>();
        Set<Id> deferredMainIds = new Set<Id>();
        for (Sharing_Queue__c queue : queues) {
            Id mainId = toId(queue.Main_Record_Id__c);
            Id sourceId = toId(queue.Source_Record_Id__c);
            SObject teamMember = sourceId == null ? null : teamMembersById.get(sourceId);
            Payload payload = parsePayload(queue.Payload__c);
            Id principalId = ShareMainDirect.principalIdFor(cfg, teamMember, payload);
            if (mainId == null || principalId == null) continue;
            if (String.isBlank(ShareMainDirect.shareLevelFor(
                    cfg, teamMember, payload, mainId, principalId, noFallbackQuery))) {
                deferredMainIds.add(mainId);
            }
        }

        Map<Id, List<SObject>> teamMembersByMain = noFallbackQuery;
        if (!deferredMainIds.isEmpty()) {
            teamMembersByMain = new Map<Id, List<SObject>>();
            for (SObject tm : TeamMemberSharingService.queryTeamMembers(deferredMainIds, cfg)) {
                Id parentId = (Id) tm.get(cfg.teamMemberConfig.parentLookupField);
                if (parentId == null) continue;
                if (!teamMembersByMain.containsKey(parentId)) {
                    teamMembersByMain.put(parentId, new List<SObject>());
                }
                teamMembersByMain.get(parentId).add(tm);
            }
        }

        for (Sharing_Queue__c queue : queues) {
            Integer cpuBefore = Limits.getCpuTime();
            debugJobExecution(queue, 'start', cpuBefore, null, null);
            Id sourceId = toId(queue.Source_Record_Id__c);
            SObject teamMember = sourceId == null ? null : teamMembersById.get(sourceId);
            Integer count = appendMainDirectShares(
                ShareMainDirect.sharesForQueue(queue, teamMember, teamMembersByMain),
                queue.Id,
                pendingShares,
                queueIdsByShareKey);
            processedByQueue.put(queue.Id, count);
            succeeded.add(queue);
            debugJobExecution(queue, 'done', cpuBefore, count, null);
        }
    }

    /**
     * @description Appends main shares and records which queue produced each share key.
     * @author Melissa Rainboldt
     * @param shares Share sObjects to insert, update, delete, or inspect.
     * @param queueId Sharing Queue Id that produced these shares.
     * @param pendingShares Share sObjects collected for a single insert.
     * @param queueIdsByShareKey Sharing Queue Ids that produced each share key.
     * @return How many share rows were appended for the queue.
     */
    private static Integer appendMainDirectShares(
            List<SObject> shares,
            Id queueId,
            List<SObject> pendingShares,
            Map<String, Set<Id>> queueIdsByShareKey) {
        Integer count = 0;
        if (shares == null) return 0;
        for (SObject share : shares) {
            if (share == null) continue;
            pendingShares.add(share);
            String key = TeamMemberSharingService.shareRowKey(share);
            if (String.isNotBlank(key) && queueId != null) {
                if (!queueIdsByShareKey.containsKey(key)) {
                    queueIdsByShareKey.put(key, new Set<Id>());
                }
                queueIdsByShareKey.get(key).add(queueId);
            }
            count++;
        }
        return count;
    }

    /**
     * @description Related record ShareRelatedToAllTeamMembers shares. Payload wins,
     * otherwise Source_Object_Api_Name__c on the queue row.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return The related child object API name, or null when neither the payload nor the queue has
     * one.
     */
    public static String relatedChildObjectApiName(Sharing_Queue__c queue) {
        if (queue == null) return null;
        Payload payload = parsePayload(queue.Payload__c);
        if (String.isNotBlank(payload.relatedObjectApiName)) {
            return payload.relatedObjectApiName;
        }
        return queue.Source_Object_Api_Name__c;
    }

    /**
     * @description Dispatches the child scope to the queue rows' batch handler.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param children Child records in the current scope.
     * @return The number of share rows written for the chunk.
     */
    public static Integer processChildChunk(Sharing_Queue__c queue, List<SObject> children) {
        return processChildChunk(new List<Sharing_Queue__c>{ queue }, children);
    }

    /**
     * @description Dispatches the child scope to the queue rows' batch handler.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param children Child records in the current scope.
     * @return The number of share rows written for the chunk.
     */
    public static Integer processChildChunk(List<Sharing_Queue__c> queues, List<SObject> children) {
        if (queues == null || queues.isEmpty()) return 0;
        String handler = queues[0].Job__r == null ? null : queues[0].Job__r.Handler__c;
        return SharingQueueHandlerRegistry.resolve(handler).processChunk(queues, children);
    }

    /**
     * @description Logs CPU and records processed for a queue phase.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param phase Timing label, such as start, done, or finish.
     * @param cpuBefore CPU time in milliseconds at the start of the phase.
     * @param recordsProcessed Share-row count recorded for the queue.
     * @return void
     */
    public static void debugJobExecution(
            Sharing_Queue__c queue,
            String phase,
            Integer cpuBefore,
            Integer recordsProcessed) {
        debugJobExecution(queue, phase, cpuBefore, recordsProcessed, null);
    }

    /**
     * @description Logs CPU and records processed for a queue phase.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param phase Timing label, such as start, done, or finish.
     * @param cpuBefore CPU time in milliseconds at the start of the phase.
     * @param recordsProcessed Share-row count recorded for the queue.
     * @param childObjectApiName API name of the related child object.
     * @return void
     */
    public static void debugJobExecution(
            Sharing_Queue__c queue,
            String phase,
            Integer cpuBefore,
            Integer recordsProcessed,
            String childObjectApiName) {
        Integer cpuTime = Limits.getCpuTime();
        String message = 'SharingQueue ' + phase
            + ': jobName=' + jobField(queue, 'Name')
            + ', handler=' + jobField(queue, 'Handler__c')
            + ', processor=' + jobField(queue, 'Processor__c')
            + ', cpuTime=' + cpuTime
            + ', cpuElapsed=' + (cpuTime - cpuBefore);
        if (String.isNotBlank(childObjectApiName)) {
            message += ', childObject=' + childObjectApiName;
        }
        if (recordsProcessed != null) {
            message += ', recordsProcessed=' + recordsProcessed;
        }
        LimitsHelper.logLimits(message);
    }

    /**
     * @description Child-axis share DML used by Batch handlers.
     * allTeamMembers true = Reconcile (every TM, always rebuild).
     * false = fan-out (payload User/Group, rebuild on update/delete/sweep).
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param children Child records in the current scope.
     * @param allTeamMembers When true, rebuild every team member. When false, use the user or group
     * on the payload.
     * @return The number of share rows written for the chunk.
     */
    public static Integer shareChildChunk(
            List<Sharing_Queue__c> queues,
            List<SObject> children,
            Boolean allTeamMembers) {
        if (queues == null || queues.isEmpty() || children == null || children.isEmpty()) {
            return 0;
        }

        SharingConfigService cfg = SharingConfigService.getInstance(queues[0].Application__c);
        String childApi = children[0].getSObjectType().getDescribe().getName();
        SharingConfigService.ObjectConfig oc = sliceConfig(cfg, childApi);
        if (oc == null) return 0;

        Id mainId = toId(queues[0].Main_Record_Id__c);
        Set<Id> childIds = new Set<Id>();
        for (SObject child : children) {
            childIds.add((Id) child.get('Id'));
        }

        Boolean allUsers = allTeamMembers == true;
        Set<Id> scopedUsers = new Set<Id>();
        Boolean rebuild = allUsers;
        for (Sharing_Queue__c queue : queues) {
            Payload payload = parsePayload(queue.Payload__c);
            Id scopedUserId = toId(payload.userOrGroupId);
            if (scopedUserId != null) scopedUsers.add(scopedUserId);
            if (queue.Trigger_Event__c == JobCatalogService.EVENT_TEAM_MEMBER_UPDATED
                    || queue.Trigger_Event__c == JobCatalogService.EVENT_TEAM_MEMBER_DELETED
                    || queue.Trigger_Event__c == JobCatalogService.EVENT_RECONCILE_SWEEP) {
                rebuild = true;
            }
        }
        if (allUsers) {
            scopedUsers = null;
            rebuild = true;
        } else if (scopedUsers.isEmpty()) {
            scopedUsers = null;
        }

        if (rebuild) {
            deleteEngineShares(oc, childIds, scopedUsers);
        }

        List<SObject> teamMembers = TeamMemberSharingService.queryTeamMembers(
            new Set<Id>{ mainId }, cfg);
        if (teamMembers.isEmpty()) return 0;

        Map<Id, Map<Id, String>> levelByParent = TeamMemberSharingService.maxShareLevelByParentAndPrincipal(
            teamMembers, cfg, oc);
        Map<Id, String> byPrincipal = levelByParent.get(mainId);
        if (byPrincipal == null || byPrincipal.isEmpty()) return 0;

        List<SObject> shares = new List<SObject>();
        for (SObject child : children) {
            Id childId = (Id) child.get('Id');
            for (Id principalId : byPrincipal.keySet()) {
                if (scopedUsers != null && !scopedUsers.contains(principalId)) continue;
                String accessLevel = byPrincipal.get(principalId);
                if (SharingConfigService.owdAlreadyGrants(oc.childObjectApiName, accessLevel)) {
                    continue;
                }
                SObject share = (SObject) Type.forName(oc.shareObjectApiName).newInstance();
                share.put('ParentId', childId);
                share.put('UserOrGroupId', principalId);
                share.put('AccessLevel', accessLevel);
                share.put('RowCause', oc.rowCause);
                shares.add(share);
            }
        }
        return TeamMemberSharingService.insertShares(shares);
    }

    /**
     * @description Lists child object API names configured for the application.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @return Child object API names configured for the application.
     */
    public static List<String> relatedObjectApiNames(SharingConfigService cfg) {
        List<String> names = new List<String>();
        Set<String> seen = new Set<String>();
        for (SharingConfigService.ObjectConfig oc : cfg.objectConfigs) {
            String key = oc.childObjectApiName.toLowerCase();
            if (seen.contains(key)) continue;
            seen.add(key);
            names.add(oc.childObjectApiName);
        }
        return names;
    }

    /**
     * @description Returns the object slices the payload asked to process.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param objectApiNames Child object API names. Blank means every configured slice.
     * @return Object slices to iterate for the names, or every slice when the names are blank.
     */
    public static List<SharingConfigService.ObjectConfig> relatedSlices(
            SharingConfigService cfg,
            List<String> objectApiNames) {
        return cfg.slicesForObjects(objectApiNames);
    }

    /**
     * @description Returns the object slice for the child API name.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param childApi Child object API name of the slice.
     * @return The object slice for the child API name, or null when none is configured.
     */
    private static SharingConfigService.ObjectConfig sliceConfig(
            SharingConfigService cfg,
            String childApi) {
        if (activeSliceConfigId != null && cfg.objectConfigById.containsKey(activeSliceConfigId)) {
            SharingConfigService.ObjectConfig slice = cfg.objectConfigById.get(activeSliceConfigId);
            if (childApi == null
                    || slice.childObjectApiName.toLowerCase() == childApi.toLowerCase()) {
                return slice;
            }
        }
        return cfg.objectConfigByApiName.get(childApi == null ? '' : childApi.toLowerCase());
    }

    //Helpers

    /**
     * @description Inserts event-only Sharing Queue rows.
     * @author Melissa Rainboldt
     * @param events Event-only Sharing Queue rows to insert.
     * @return The number of event rows inserted.
     */
    private static Integer insertEvents(List<Sharing_Queue__c> events) {
        if (events.isEmpty()) return 0;
        insert events;
        return events.size();
    }

    /**
     * @description Explains why the event row has no usable head Job.
     * @author Melissa Rainboldt
     * @param eventRow Event row whose catalog mapping is explained.
     * @return The reason the event has no usable head Job.
     */
    private static String missingMappingMessage(Sharing_Queue__c eventRow) {
        return JobCatalogService.describeMiss(
            eventRow.Trigger_Event__c,
            eventRow.Application__c);
    }

    /**
     * @description Builds an event-only Sharing Queue row. Job is left blank so the trigger expands
     * the chain.
     * @author Melissa Rainboldt
     * @param mainId Main record Id.
     * @param mainApi API name of the main object.
     * @param triggerEvent Trigger event key used to resolve the head Job.
     * @param sourceId Source record Id, such as a team member or child.
     * @param sourceApi API name of the source object.
     * @param payloadJson Serialized payload.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return An unsaved event-only Sharing Queue row.
     */
    private static Sharing_Queue__c newEvent(
            Id mainId,
            String mainApi,
            String triggerEvent,
            Id sourceId,
            String sourceApi,
            String payloadJson,
            String application) {
        return new Sharing_Queue__c(
            Trigger_Event__c = triggerEvent,
            Main_Record_Id__c = String.valueOf(mainId),
            Main_Object_Api_Name__c = mainApi,
            Source_Record_Id__c = sourceId == null ? null : String.valueOf(sourceId),
            Source_Object_Api_Name__c = sourceApi,
            Application__c = application,
            Status__c = STATUS_PENDING,
            Is_Chain_Step__c = false,
            Retry_Count__c = 0,
            Payload__c = payloadJson
        );
    }

    /**
     * @description Returns dedupe keys for open rows that match this main, job, source, and
     * application.
     * @author Melissa Rainboldt
     * @param mainIds Main record Ids.
     * @param head Head Job. Null when the catalog has no mapping.
     * @param sourceIds Source record Ids used to match open queue rows.
     * @param triggerEvent Trigger event key used to resolve the head Job.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return Dedupe keys of matching open queue rows.
     */
    private static Set<String> queryOpenKeys(
            Set<String> mainIds,
            Job__c head,
            Set<Id> sourceIds,
            String triggerEvent,
            String application) {
        Set<String> keys = new Set<String>();
        if (mainIds == null || mainIds.isEmpty() || String.isBlank(application)) return keys;

        List<Sharing_Queue__c> existing = [
            SELECT Main_Record_Id__c, Job__c, Source_Record_Id__c, Trigger_Event__c, Application__c
            FROM Sharing_Queue__c
            WHERE Status__c IN :OPEN_STATUSES
            AND Main_Record_Id__c IN :mainIds
            AND Application__c = :application
        ];
        Set<String> sourceFilter = new Set<String>();
        for (Id sourceId : sourceIds) {
            if (sourceId != null) sourceFilter.add(String.valueOf(sourceId));
        }
        Boolean filterSource = !sourceFilter.isEmpty();
        Id headId = head == null ? null : head.Id;
        for (Sharing_Queue__c row : existing) {
            if (row.Application__c != application) continue;
            if (filterSource
                    && String.isNotBlank(row.Source_Record_Id__c)
                    && !sourceFilter.contains(row.Source_Record_Id__c)) {
                continue;
            }
            Boolean sameJob = (headId != null && row.Job__c == headId)
                || (row.Job__c == null && row.Trigger_Event__c == triggerEvent);
            if (!sameJob) continue;
            keys.add(coalesceKey(
                row.Main_Record_Id__c, headId, row.Source_Record_Id__c, application));
        }
        return keys;
    }

    /**
     * @description Builds the dedupe key from main, job, source, and application.
     * @author Melissa Rainboldt
     * @param mainId Main record Id.
     * @param jobId Job Id.
     * @param sourceId Source record Id, such as a team member or child.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The dedupe key for main, job, source, and application.
     */
    private static String coalesceKey(String mainId, Id jobId, String sourceId, String application) {
        return mainId + '|' + String.valueOf(jobId) + '|'
            + (sourceId == null ? '' : sourceId) + '|' + application;
    }

    /**
     * @description Builds the compaction group key from main and application.
     * @author Melissa Rainboldt
     * @param mainId Main record Id.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The compaction group key for main and application.
     */
    private static String compactGroupKey(String mainId, String application) {
        return mainId + '|' + application;
    }

    /**
     * @description Returns whether this insert or update should enqueue. Role, access, principal,
     * and active are the watched fields.
     * @author Melissa Rainboldt
     * @param rec Current sObject.
     * @param oldMap Prior records keyed by Id. Null on insert.
     * @param tmc Team member field mapping for the application.
     * @return True on insert, or when a watched team-member field changed.
     */
    private static Boolean isRelevantTeamMemberChange(
            SObject rec,
            Map<Id, SObject> oldMap,
            SharingConfigService.TeamMemberConfig tmc) {
        if (oldMap == null) return true;
        SObject oldRec =oldMap.get((Id) rec.get('Id'));
        if (oldRec == null) return true;
        if (fieldChanged(rec, oldRec, tmc.roleField)) return true;
        if (fieldChanged(rec, oldRec, tmc.accessLevelField)) return true;
        if (fieldChanged(rec, oldRec, tmc.userField)) return true;
        if (fieldChanged(rec, oldRec, tmc.groupField)) return true;
        if (fieldChanged(rec, oldRec, tmc.activeField)) return true;
        return false;
    }

    /**
     * @description Returns whether the field differs between the two records.
     * @author Melissa Rainboldt
     * @param rec Current sObject.
     * @param oldRec Previous version of the sObject.
     * @param fieldApi API name of the field to read or compare.
     * @return True when the field values differ.
     */
    private static Boolean fieldChanged(SObject rec, SObject oldRec, String fieldApi) {
        if (String.isBlank(fieldApi)) return false;
        return rec.get(fieldApi) != oldRec.get(fieldApi);
    }

    /**
     * @description Resolves the main share level from team-member access or from role-access
     * permissions. All is stored as Edit.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param role Team member role.
     * @param al Team member access level before it is normalized.
     * @return The share access level to write, or null when it cannot be resolved.
     */
    public static String resolveShareLevel(SharingConfigService cfg, String role, String al) {
        if (cfg == null) return null;
        if (cfg.teamMemberConfig != null && cfg.teamMemberConfig.useTeamMemberAccessLevel) {
            String lvl = SharingConfigService.normalizeShareLevel(al);
            if (lvl == 'All') return 'Edit';
            return lvl;
        }
        String best;
        for (SharingConfigService.ObjectConfig oc : cfg.objectConfigs) {
            String lvl = cfg.getShareAccessLevel(role, al, oc);
            if (String.isBlank(lvl)) continue;
            if (lvl == 'All') lvl = 'Edit';
            best = TeamMemberSharingService.maxAccess(best, lvl);
        }
        return best;
    }

    /**
     * @description Returns the row cause of the first object config.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @return The first configured row cause, or null when the application has no object config.
     */
    public static String firstRowCause(SharingConfigService cfg) {
        if (cfg == null || cfg.objectConfigs.isEmpty()) return null;
        return cfg.objectConfigs[0].rowCause;
    }

    /**
     * @description RowCause for a specific object (typically Main). Uses a Sharing Object
     * Config whose child API name matches. Related-object causes are not valid
     * on Main, so unmatched objects use Manual.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param objectApiName API name of the sObject.
     * @return The row cause for that object, or Manual when no slice matches.
     */
    public static String rowCauseForObject(SharingConfigService cfg, String objectApiName) {
        if (cfg != null && String.isNotBlank(objectApiName)) {
            for (SharingConfigService.ObjectConfig oc : cfg.objectConfigs) {
                if (oc.childObjectApiName != null
                        && oc.childObjectApiName.equalsIgnoreCase(objectApiName)
                        && String.isNotBlank(oc.rowCause)) {
                    return oc.rowCause;
                }
            }
        }
        return 'Manual';
    }

    /**
     * @description Deletes Apex shares on each main for principals who are not active team members.
     * Uses the same row cause ShareMainDirect writes. An empty active set deletes every share
     * with that row cause on the main.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this reconcile batch.
     * @return void
     */
    public static void unshareInactivePrincipalsOnMain(List<Sharing_Queue__c> queues) {
        if (queues == null || queues.isEmpty()) return;

        Map<String, Sharing_Queue__c> byMain = new Map<String, Sharing_Queue__c>();
        for (Sharing_Queue__c queue : queues) {
            if (queue == null
                    || String.isBlank(queue.Application__c)
                    || String.isBlank(queue.Main_Record_Id__c)
                    || String.isBlank(queue.Main_Object_Api_Name__c)) {
                continue;
            }
            byMain.put(
                queue.Application__c + '|' + queue.Main_Record_Id__c + '|'
                    + queue.Main_Object_Api_Name__c,
                queue);
        }

        for (Sharing_Queue__c queue : byMain.values()) {
            Id mainId = toId(queue.Main_Record_Id__c);
            if (mainId == null) continue;

            SharingConfigService cfg = SharingConfigService.getInstance(queue.Application__c);
            Set<Id> activePrincipals = new Set<Id>();
            for (SObject teamMember : TeamMemberSharingService.queryTeamMembers(
                    new Set<Id>{ mainId }, cfg)) {
                Id principalId = TeamMemberSharingService.userOrGroupId(
                    teamMember, cfg.teamMemberConfig);
                if (principalId != null) activePrincipals.add(principalId);
            }

            String rowCause = rowCauseForObject(cfg, queue.Main_Object_Api_Name__c);
            String shareApi = SharingConfigService.deriveShareObjectName(
                queue.Main_Object_Api_Name__c);
            String soql = 'SELECT Id FROM ' + shareApi
                + ' WHERE ParentId = :mainId'
                + ' AND RowCause = \'' + String.escapeSingleQuotes(rowCause) + '\'';
            if (!activePrincipals.isEmpty()) {
                soql += ' AND UserOrGroupId NOT IN :activePrincipals';
            }
            TeamMemberSharingService.deleteShares(Database.query(soql));
        }
    }

    /**
     * @description Deletes engine-owned shares for the children and optional users.
     * @author Melissa Rainboldt
     * @param oc Sharing object configuration slice.
     * @param childIds Child record Ids whose engine shares are deleted.
     * @param userIds User or group Ids to include. Null means every principal.
     * @return void
     */
    private static void deleteEngineShares(
            SharingConfigService.ObjectConfig oc,
            Set<Id> childIds,
            Set<Id> userIds) {
        if (childIds == null || childIds.isEmpty()) return;
        String q = 'SELECT Id FROM ' + oc.shareObjectApiName
            + ' WHERE ParentId IN :childIds'
            + ' AND RowCause = \'' + String.escapeSingleQuotes(oc.rowCause) + '\'';
        if (userIds != null && !userIds.isEmpty()) {
            q += ' AND UserOrGroupId IN :userIds';
        }
        TeamMemberSharingService.deleteShares(Database.query(q));
    }

    /**
     * @description Sets the queue to Failed and stores a non-blank Last Error.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param message Error text to store or trim.
     * @return void
     */
    private static void applyFailedStatus(Sharing_Queue__c queue, String message) {
        queue.Status__c = STATUS_FAILED;
        queue.Last_Error__c = requiredError(message);
        queue.Processed_Date__c = null;
    }

    /**
     * @description Returns a non-blank error message, truncated to the Last Error length.
     * @author Melissa Rainboldt
     * @param message Error text to store or trim.
     * @return A non-blank error message truncated to the Last Error length.
     */
    private static String requiredError(String message) {
        String text = truncateError(message);
        return String.isBlank(text) ? 'Unknown error' : text;
    }

    /**
     * @description Casts the text to an Id. Blank returns null.
     * @author Melissa Rainboldt
     * @param value Text Id. Blank returns null.
     * @return The Id, or null when the text is blank.
     */
    public static Id toId(String value) {
        if (String.isBlank(value)) return null;
        return (Id) value;
    }

    /**
     * @description Returns a queried Job field value, or null when it was not populated.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param fieldName API name of the field on the related Job.
     * @return The Job field value, or null when it was not queried.
     */
    private static String jobField(Sharing_Queue__c queue, String fieldName) {
        if (queue == null || queue.Job__r == null || String.isBlank(fieldName)) return null;
        Map<String, Object> populated = queue.Job__r.getPopulatedFieldsAsMap();
        if (!populated.containsKey(fieldName) || populated.get(fieldName) == null) return null;
        return String.valueOf(populated.get(fieldName));
    }

    /**
     * @description Returns the first queried Job field that has a value.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param fieldNames Job field API names tried in order.
     * @return The first non-blank Job field value, or null.
     */
    private static String firstPopulated(Sharing_Queue__c queue, List<String> fieldNames) {
        if (fieldNames == null) return null;
        for (String fieldName : fieldNames) {
            String value = jobField(queue, fieldName);
            if (String.isNotBlank(value)) return value;
        }
        return null;
    }

    /**
     * @description Truncates an error to the Last Error field length.
     * @author Melissa Rainboldt
     * @param message Error text to store or trim.
     * @return The message truncated to the Last Error field length. Null stays null.
     */
    private static String truncateError(String message) {
        System.debug(LoggingLevel.ERROR, 'SharingQueueService Error: ' + message);
        if (message == null) return null;
        return message.length() <= LAST_ERROR_MAX_LEN
            ? message
            : message.substring(0, LAST_ERROR_MAX_LEN);
    }
}
