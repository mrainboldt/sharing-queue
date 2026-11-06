/**
 * @description Claims a slice of compatible Pending Batch Sharing_Queue__c rows
 * (same catalog Job + same Main + same Application, up to BATCH_CLAIM_LIMIT) and iterates
 * that Main's related children once. Fifty Team Member adds on one Project
 * become one child QueryLocator, not fifty Batch Apex jobs.
 *
 * execute() DML ≈ scope × claimed queue rows. Default 200 × 40 = 8,000.
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    @TestVisible static final Integer BATCH_SCOPE = 200;

    private List<Id> queueIds;
    private Map<Id, Id> executionIdByQueueId;
    private Integer objectIndex;
    private List<Sharing_Queue__c> queues;
    private Map<Id, Job_Execution__c> executionsByQueueId;
    private SharingQueueService.Payload payload;
    private List<String> sliceKeys;
    private Integer recordsProcessed = 0;
    private Boolean hadError = false;
    private String lastError;
    private Id bindMainId;
    private String bindLastId;
    private String currentSliceKey;
    private String currentChildObjectApiName;
    private Integer cpuBefore;
    private VolumeLimits peakUsage;

    /**
     * @description Creates a batch that claims a compatible pending slice when start runs.
     * @author Melissa Rainboldt
     * @return A new SharingQueueBatch instance.
     */
    public SharingQueueBatch() {
        this(null, 0, null, null);
    }

    /**
     * @description Creates a batch for an already claimed slice at the given object-config index.
     * @author Melissa Rainboldt
     * @param queueIds Sharing Queue Ids this batch execution owns. Null claims a slice in start.
     * @param objectIndex Index of the sharing-object slice this run processes.
     * @param executionIdByQueueId Job execution Ids keyed by Sharing Queue Id.
     * @return A new SharingQueueBatch instance.
     */
    public SharingQueueBatch(List<Id> queueIds, Integer objectIndex, Map<Id, Id> executionIdByQueueId) {
        this(queueIds, objectIndex, executionIdByQueueId, null);
    }

    /**
     * @description Creates a batch for the next object-config slice and carries the governor peak
     * from earlier slices.
     * @author Melissa Rainboldt
     * @param queueIds Sharing Queue Ids this batch execution owns. Null claims a slice in start.
     * @param objectIndex Index of the sharing-object slice this run processes.
     * @param executionIdByQueueId Job execution Ids keyed by Sharing Queue Id.
     * @param peakUsage Highest governor usage seen on earlier slices.
     * @return A new SharingQueueBatch instance.
     */
    public SharingQueueBatch(
            List<Id> queueIds,
            Integer objectIndex,
            Map<Id, Id> executionIdByQueueId,
            VolumeLimits peakUsage) {
        this.queueIds = queueIds;
        this.objectIndex = objectIndex == null ? 0 : objectIndex;
        this.executionIdByQueueId = executionIdByQueueId;
        this.peakUsage = peakUsage;
    }

    /**
     * @description Starts one SharingQueueBatch when pending Batch rows exist and no batch worker
     * is already active.
     * @author Melissa Rainboldt
     * @return void
     */
    public static void startIfPending() {
        startIfPending(null);
    }

    /**
     * @description Starts one SharingQueueBatch when pending Batch rows exist and no batch worker
     * is already active.
     * @author Melissa Rainboldt
     * @param excludeJobId Running Batch job to ignore so finish can chain a successor.
     * @return void
     */
    public static void startIfPending(Id excludeJobId) {
        if (SharingQueueService.suppressAsyncKick) return;
        SharingQueueService.compactOpenWork();
        String batchKind = JobCatalogService.PROCESSOR_BATCH;
        Integer pending = [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Status__c = :SharingQueueService.STATUS_PENDING
            AND Job__c != null
            AND Job__r.Processor__c = :batchKind
            LIMIT 1
        ];
        if (pending == 0) {
            return;
        }
        if (SharingQueueService.activeWorkerCount(
                SharingQueueService.BATCH_WORKER, excludeJobId) > 0) {
            return;
        }
        try {
            Database.executeBatch(new SharingQueueBatch(), BATCH_SCOPE);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'SharingQueueBatch.startIfPending skipped: ' + e.getMessage());
        }
    }

    /**
     * @description Claims a compatible slice when this run does not have one yet, then returns the
     * child query for the current object config.
     * @author Melissa Rainboldt
     * @param bc Batchable context for this start.
     * @return The child query locator for this slice, or an empty locator when there is nothing to
     * process.
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        cpuBefore = Limits.getCpuTime();
        if (queueIds == null || queueIds.isEmpty()) {
            SharingQueueService.compactOpenWork();
            SharingQueueService.ClaimResult claimed = SharingQueueService.claimCompatibleBatchSlice(
                bc == null ? null : bc.getJobId());
            if (claimed.queues.isEmpty()) {
                return emptyLocator();
            }
            queues = claimed.queues;
            executionsByQueueId = claimed.executionsByQueueId;
            queueIds = new List<Id>();
            executionIdByQueueId = new Map<Id, Id>();
            for (Sharing_Queue__c queue : queues) {
                queueIds.add(queue.Id);
                Job_Execution__c execution = executionsByQueueId.get(queue.Id);
                if (execution != null) {
                    executionIdByQueueId.put(queue.Id, execution.Id);
                }
            }
        } else {
            queues = queryQueues(queueIds);
            executionsByQueueId = queryExecutions(executionIdByQueueId);
            if (queues.isEmpty()) {
                return emptyLocator();
            }
            if (queues[0].Status__c == SharingQueueService.STATUS_PENDING) {
                SharingQueueService.ClaimResult claimed = SharingQueueService.claimQueues(
                    queues, bc == null ? null : bc.getJobId());
                queues = claimed.queues;
                executionsByQueueId = claimed.executionsByQueueId;
            }
        }

        if (objectIndex == 0) {
            dropInactiveMainShares(queues);
        }

        payload = SharingQueueService.parsePayload(queues[0].Payload__c);
        SharingConfigService cfg = SharingConfigService.getInstance(queues[0].Application__c);
        List<SharingConfigService.ObjectConfig> slices =
            SharingQueueService.relatedSlices(
                cfg,
                payload.relatedObjectApiNames);
        sliceKeys = new List<String>();
        for (SharingConfigService.ObjectConfig slice : slices) {
            sliceKeys.add(String.valueOf(slice.configId));
        }
        if (sliceKeys.isEmpty() || objectIndex >= sliceKeys.size()) {
            return emptyLocator();
        }

        currentSliceKey = sliceKeys[objectIndex];
        SharingConfigService.ObjectConfig oc =
            cfg.objectConfigById.get((Id) currentSliceKey);
        if (oc == null) {
            hadError = true;
            lastError = 'No Sharing_Object_Config__c for slice ' + currentSliceKey;
            return emptyLocator();
        }

        bindMainId = (Id) queues[0].Main_Record_Id__c;
        currentChildObjectApiName = oc.childObjectApiName;
        SharingQueueService.debugJobExecution(
            queues[0], 'start', cpuBefore, null, currentChildObjectApiName);
        if (SharingConfigService.owdAlreadyGrants(oc.childObjectApiName, 'Edit')) {
            System.debug(LoggingLevel.INFO, 'SharingQueueBatch skipped slice: OWD already grants Edit on '
                + oc.childObjectApiName);
            return emptyLocator();
        }
        return Database.getQueryLocator(sliceQuery(oc));
    }

    /**
     * @description Shares this child scope for every claimed queue row and saves the cursor.
     * @author Melissa Rainboldt
     * @param bc Batchable context. Null when the batch is drained inline in a test.
     * @param scope Records in this batch chunk.
     * @return void
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        if (hadError || queues == null || queues.isEmpty() || scope.isEmpty()) return;
        SharingQueueService.activeSliceConfigId = currentSliceKey == null ? null : (Id) currentSliceKey;
        try {
            recordsProcessed += SharingQueueService.processChildChunk(queues, scope);
            payload.cursorObject = currentSliceKey;
            payload.cursorLastId = String.valueOf(scope[scope.size() - 1].get('Id'));
            SharingQueueService.persistCursors(queues, payload, recordsProcessed);
        } catch (Exception e) {
            hadError = true;
            lastError = e.getMessage() + '\n' + e.getStackTraceString();
        } finally {
            SharingQueueService.activeSliceConfigId = null;
            recordPeakUsage();
        }
    }

    /**
     * @description Keeps the higher governor usage seen in this execute.
     * @author Melissa Rainboldt
     * @return void
     */
    private void recordPeakUsage() {
        VolumeLimits snap = VolumeLimits.capture();
        peakUsage = peakUsage == null ? snap : peakUsage.maxUsed(snap);
    }

    /**
     * @description Chains the next object-config slice, or completes the claimed rows and kicks
     * workers.
     * @author Melissa Rainboldt
     * @param bc Batchable context for this finish.
     * @return void
     */
    public void finish(Database.BatchableContext bc) {
        cpuBefore = Limits.getCpuTime();
        if (queues == null || queues.isEmpty()) return;

        SharingQueueService.debugJobExecution(
            queues[0],
            hadError ? 'finish-error' : 'finish',
            cpuBefore,
            recordsProcessed,
            currentChildObjectApiName);

        if (hadError) {
            SharingQueueService.markFailed(
                queues, executionsByQueueId, lastError, recordsProcessed, peakUsage);
            return;
        }

        Integer nextIndex = objectIndex + 1;
        if (sliceKeys != null && nextIndex < sliceKeys.size()) {
            payload.cursorObject = sliceKeys[nextIndex];
            payload.cursorLastId = null;
            SharingQueueService.persistCursors(queues, payload, recordsProcessed);
            if (Test.isRunningTest()) {
                drainRemainingSlices();
                if (hadError) {
                    SharingQueueService.markFailed(
                        queues, executionsByQueueId, lastError, recordsProcessed, peakUsage);
                    return;
                }
            } else {
                try {
                    Database.executeBatch(
                        new SharingQueueBatch(queueIds, nextIndex, executionIdByQueueId, peakUsage),
                        BATCH_SCOPE);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR,
                        'SharingQueueBatch next slice skipped: ' + e.getMessage());
                }
                return;
            }
        }

        Map<Id, Integer> processed = new Map<Id, Integer>();
        for (Sharing_Queue__c queue : queues) {
            processed.put(queue.Id, recordsProcessed);
        }
        SharingQueueService.markCompleted(queues, executionsByQueueId, processed, peakUsage);
        SharingQueueQueueable.enqueueOnce();
        startIfPending(bc == null ? null : bc.getJobId());
    }

    /**
     * @description One compatible Batch slice in this transaction: start, execute scopes,
     * finish (which drains remaining object-config slices in tests). Used by
     * VolumeHarness so Batch governors are counted without Test.stopTest().
     * @author Melissa Rainboldt
     * @return True when a pending slice was claimed and processed.
     */
    public static Boolean drainOnePendingSlice() {
        SharingQueueBatch batch = new SharingQueueBatch();
        Database.QueryLocator locator = batch.start(null);
        if (batch.queues == null || batch.queues.isEmpty()) {
            return false;
        }
        List<SObject> scope = new List<SObject>();
        Database.QueryLocatorIterator rows = locator.iterator();
        while (rows.hasNext()) {
            scope.add(rows.next());
            if (scope.size() == BATCH_SCOPE) {
                batch.execute(null, scope);
                scope = new List<SObject>();
            }
        }
        if (!scope.isEmpty()) {
            batch.execute(null, scope);
        }
        batch.finish(null);
        return true;
    }

    /**
     * @description Test.stopTest() runs the first Batch Apex job but not jobs chained from
     * finish(). Remaining Sharing Object Config slices are processed inline.
     * @author Melissa Rainboldt
     * @return void
     */
    private void drainRemainingSlices() {
        SharingConfigService cfg = SharingConfigService.getInstance(queues[0].Application__c);
        bindMainId = (Id) queues[0].Main_Record_Id__c;
        for (Integer i = objectIndex + 1; i < sliceKeys.size(); i++) {
            objectIndex = i;
            currentSliceKey = sliceKeys[i];
            SharingConfigService.ObjectConfig oc =
                cfg.objectConfigById.get((Id) currentSliceKey);
            if (oc == null) {
                hadError = true;
                lastError = 'No Sharing_Object_Config__c for slice ' + currentSliceKey;
                break;
            }
            payload.cursorLastId = null;
            payload.cursorObject = currentSliceKey;
            List<SObject> children = Database.query(sliceQuery(oc));
            Integer fromIndex = 0;
            while (fromIndex < children.size()) {
                Integer toIndex = Math.min(fromIndex + BATCH_SCOPE, children.size());
                List<SObject> scope = new List<SObject>();
                for (Integer j = fromIndex; j < toIndex; j++) {
                    scope.add(children[j]);
                }
                execute(null, scope);
                fromIndex = toIndex;
            }
        }
    }

    /**
     * @description Builds the child query for the bound main, honoring the cursor when this slice
     * already started.
     * @author Melissa Rainboldt
     * @param oc Sharing object configuration slice.
     * @return The SOQL for the current child slice.
     */
    private String sliceQuery(SharingConfigService.ObjectConfig oc) {
        String q = 'SELECT Id, ' + oc.selectParentFields()
            + ' FROM ' + oc.childObjectApiName
            + ' WHERE ' + oc.whereParentEquals('bindMainId')
            + oc.andFilterClause();
        if (String.isNotBlank(payload.cursorLastId)
                && payload.cursorObject == currentSliceKey) {
            bindLastId = payload.cursorLastId;
            q += ' AND Id > :bindLastId';
        }
        q += ' ORDER BY Id ASC';
        return q;
    }

    /**
     * @description Deletes main shares for inactive principals when this slice is a reconcile.
     * Runs once, before an empty child list returns, so a main with no related records still
     * loses the share.
     * @author Melissa Rainboldt
     * @param claimed Sharing Queue rows claimed for this batch.
     * @return void
     */
    private static void dropInactiveMainShares(List<Sharing_Queue__c> claimed) {
        if (claimed == null || claimed.isEmpty()) return;
        String handlerName = claimed[0].Job__r == null ? null : claimed[0].Job__r.Handler__c;
        SharingQueueHandler handler = SharingQueueHandlerRegistry.tryResolve(handlerName);
        if (handler == null || !handler.isReconcileJob()) return;
        SharingQueueService.unshareInactivePrincipalsOnMain(claimed);
    }

    /**
     * @description Returns a query locator that yields no rows.
     * @author Melissa Rainboldt
     * @return A query locator that returns no Sharing Queue rows.
     */
    private static Database.QueryLocator emptyLocator() {
        return Database.getQueryLocator(
            'SELECT Id FROM Sharing_Queue__c WHERE Id = null');
    }

    /**
     * @description Reloads the claimed Sharing Queue rows.
     * @author Melissa Rainboldt
     * @param queueIds Sharing Queue Ids this batch execution owns. Null claims a slice in start.
     * @return The Sharing Queue rows for the Ids.
     */
    private static List<Sharing_Queue__c> queryQueues(List<Id> queueIds) {
        return [
            SELECT Id,
                   Trigger_Event__c,
                   Job__c,
                   Job__r.Handler__c,
                   Job__r.Processor__c,
                   Job__r.Name,
                   Main_Record_Id__c,
                   Main_Object_Api_Name__c,
                   Source_Record_Id__c,
                   Source_Object_Api_Name__c,
                   Status__c,
                   Next_Queue__c,
                   Retry_Count__c,
                   Payload__c,
                   Records_Processed__c,
                   Application__c
            FROM Sharing_Queue__c
            WHERE Id IN :queueIds
        ];
    }

    /**
     * @description Reloads job executions keyed by Sharing Queue Id.
     * @author Melissa Rainboldt
     * @param executionIdByQueueId Job execution Ids keyed by Sharing Queue Id.
     * @return Job executions keyed by Sharing Queue Id.
     */
    private static Map<Id, Job_Execution__c> queryExecutions(Map<Id, Id> executionIdByQueueId) {
        Map<Id, Job_Execution__c> byQueue = new Map<Id, Job_Execution__c>();
        if (executionIdByQueueId == null || executionIdByQueueId.isEmpty()) return byQueue;
        for (Job_Execution__c execution : [
            SELECT Id, Sharing_Queue__c, Job__c, Status__c, Started_At__c,
                   Records_Processed__c, Retry_Number__c, Processor_Kind__c,
                   SOQL_Queries_Used__c, SOQL_Queries_Limit__c,
                   Query_Rows_Used__c, Query_Rows_Limit__c,
                   DML_Statements_Used__c, DML_Statements_Limit__c,
                   DML_Rows_Used__c, DML_Rows_Limit__c,
                   CPU_Time_Used__c, CPU_Time_Limit__c
            FROM Job_Execution__c
            WHERE Id IN :executionIdByQueueId.values()
        ]) {
            byQueue.put(execution.Sharing_Queue__c, execution);
        }
        return byQueue;
    }
}
