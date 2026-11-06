/**
 * JobCatalogService
 *
 * Reads Job__c recipes and TriggerEvent → head Job mappings.
 * Jobs and mappings are created only by seedCatalog() during org setup or tests.
 * Queueable vs Batch is Job__c.Processor__c (catalog data). Workers filter on
 * that field.
 *
 * Expected catalog:
 *   TeamMemberCreated/Updated → ShareMainDirect → ShareAllRelatedToTeamMember
 *   RelatedRecordCreated      → ShareRelatedToAllTeamMembers
 *   TeamMemberDeleted         → ReconcileMain
 *   ReconcileSweep            → ReconcileMain
 *   Manual                    → ReconcileMain
 */
public without sharing class JobCatalogService {

    public static final String HANDLER_SHARE_MAIN_DIRECT                 = 'ShareMainDirect';
    public static final String HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS = 'ShareRelatedToAllTeamMembers';
    public static final String HANDLER_SHARE_MAIN_TO_TEAM_MEMBERS        = 'ShareMainToTeamMembers';
    public static final String HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER  = 'ShareAllRelatedToTeamMember';
    public static final String HANDLER_RECONCILE_MAIN                    = 'ReconcileMain';

    public static final String EVENT_TEAM_MEMBER_CREATED    = 'TeamMemberCreated';
    public static final String EVENT_TEAM_MEMBER_UPDATED    = 'TeamMemberUpdated';
    public static final String EVENT_TEAM_MEMBER_DELETED    = 'TeamMemberDeleted';
    public static final String EVENT_RELATED_RECORD_CREATED = 'RelatedRecordCreated';
    public static final String EVENT_RECONCILE_SWEEP        = 'ReconcileSweep';
    public static final String EVENT_MANUAL                 = 'Manual';

    public static final String PROCESSOR_QUEUEABLE = 'Queueable';
    public static final String PROCESSOR_BATCH     = 'Batch';

    public static final String APP_APPLICATION1 = 'Application1';
    public static final String APP_APPLICATION2 = 'Application2';

    private static Boolean catalogLoaded = false;
    private static Map<String, Job__c> jobsByHandler;
    private static Map<Id, Job__c> jobsById;
    private static Map<String, Id> headJobIdByEvent;

    @TestVisible
    static void resetCache() {
        catalogLoaded = false;
        jobsByHandler = null;
        jobsById = null;
        headJobIdByEvent = null;
    }

    /**
     * One-time org setup (anonymous Apex / installer) and test @TestSetup.
     * Inserts missing Jobs and event mappings, then loads the cache. Do not call from enqueue, expand, Queueable, or Batch.
     */
    public static void seedCatalog() {
        seedIfMissing();
        catalogLoaded = false;
        loadIfNeeded();
    }

    public static Job__c headJobFor(String triggerEvent, String application) {
        if (String.isBlank(application)) return null;
        loadIfNeeded();
        Id jobId = cachedJobId(triggerEvent, application);
        if (jobId == null) {
            jobId = queryJobId(triggerEvent, application);
        }
        if (jobId == null) return null;
        Job__c job = jobById(jobId);
        if (job != null) {
            return sameApplication(job.Application__c, application) ? job : null;
        }
        Job__c queried = queryActiveJob(jobId);
        if (queried == null || !sameApplication(queried.Application__c, application)) {
            return null;
        }
        return queried;
    }

    /**
     * Why headJobFor returned null. Used on Failed queue rows so Event Key
     * matches are not reported as a missing mapping when the Job is inactive.
     */
    public static String describeMiss(String triggerEvent, String application) {
        if (String.isBlank(triggerEvent)) {
            return 'Sharing_Queue__c has a blank Trigger Event.';
        }
        if (String.isBlank(application)) {
            return 'Sharing_Queue__c has a blank Application.';
        }
        List<Job_Trigger_Event__c> mappings = queryMappings(triggerEvent, application);
        if (mappings.isEmpty()) {
            return 'No Job_Trigger_Event__c with Event Key or Trigger Event = '
                + triggerEvent + ' and Application = ' + application + '.';
        }
        Job_Trigger_Event__c mapping = pickMapping(mappings, application);
        if (mapping == null) {
            return 'No Job_Trigger_Event__c with Event Key or Trigger Event = '
                + triggerEvent + ' and Application = ' + application + '.';
        }
        if (mapping.Is_Active__c != true) {
            return 'Job_Trigger_Event__c Event Key ' + mapping.Event_Key__c
                + ' is inactive.';
        }
        if (mapping.Job__c == null) {
            return 'Job_Trigger_Event__c Event Key ' + mapping.Event_Key__c
                + ' has no Job.';
        }
        if (mapping.Job__r == null || mapping.Job__r.Is_Active__c != true) {
            String jobName = mapping.Job__r == null ? String.valueOf(mapping.Job__c) : mapping.Job__r.Name;
            return 'Job_Trigger_Event__c Event Key ' + mapping.Event_Key__c
                + ' points at inactive Job ' + jobName + '.';
        }
        if (!sameApplication(mapping.Job__r.Application__c, application)) {
            return 'Job_Trigger_Event__c Event Key ' + mapping.Event_Key__c
                + ' maps to Job ' + mapping.Job__r.Name
                + ' whose Application ' + mapping.Job__r.Application__c
                + ' does not match ' + application + '.';
        }
        return 'Job_Trigger_Event__c Event Key ' + mapping.Event_Key__c
            + ' maps to Job ' + mapping.Job__r.Name
            + ' but that Job was not loaded.';
    }

    public static Job__c jobByHandler(String handler, String application) {
        if (String.isBlank(handler) || String.isBlank(application)) return null;
        loadIfNeeded();
        return jobsByHandler.get(catalogKey(application, handler));
    }

    /**
     * Head plus every Next_Job__c, in order. Small catalog — no SOQL in the loop
     * beyond the initial load.
     */
    public static List<Job__c> walkChain(Job__c head) {
        loadIfNeeded();
        List<Job__c> chain = new List<Job__c>();
        Set<Id> seen = new Set<Id>();
        Job__c current = head;
        String application = head == null ? null : head.Application__c;
        while (current != null && !seen.contains(current.Id)) {
            if (!sameApplication(current.Application__c, application)) break;
            seen.add(current.Id);
            chain.add(current);
            if (current.Next_Job__c == null) break;
            current = jobById(current.Next_Job__c);
        }
        return chain;
    }

    private static void loadIfNeeded() {
        if (catalogLoaded && jobsByHandler != null && jobsById != null && headJobIdByEvent != null) {
            return;
        }
        load();
        catalogLoaded = true;
    }

    private static Job__c jobById(Id jobId) {
        return jobId == null ? null : jobsById.get(jobId);
    }

    private static Id cachedJobId(String triggerEvent, String application) {
        String event = normalize(triggerEvent);
        if (String.isBlank(event) || String.isBlank(application)) return null;
        return headJobIdByEvent.get(catalogKey(application, event));
    }

    private static Id queryJobId(String triggerEvent, String application) {
        Job_Trigger_Event__c mapping = pickMapping(
            queryMappings(triggerEvent, application), application);
        if (mapping == null || mapping.Is_Active__c != true || mapping.Job__c == null) {
            return null;
        }
        if (mapping.Job__r != null && mapping.Job__r.Is_Active__c == true) {
            if (!sameApplication(mapping.Job__r.Application__c, application)) {
                return null;
            }
            rememberJob(mapping.Job__r);
        }
        return mapping.Job__c;
    }

    private static Job__c queryActiveJob(Id jobId) {
        if (jobId == null) return null;
        List<Job__c> jobs = [
            SELECT Id, Name, Handler__c, Next_Job__c, Processor__c, Is_Active__c, Application__c
            FROM Job__c
            WHERE Id = :jobId
            AND Is_Active__c = true
            LIMIT 1
        ];
        if (jobs.isEmpty()) return null;
        rememberJob(jobs[0]);
        return jobs[0];
    }

    private static List<Job_Trigger_Event__c> queryMappings(String triggerEvent, String application) {
        if (String.isBlank(triggerEvent) || String.isBlank(application)) {
            return new List<Job_Trigger_Event__c>();
        }
        return [
            SELECT Event_Key__c, Trigger_Event__c, Job__c, Application__c, Is_Active__c,
                   Job__r.Id, Job__r.Name, Job__r.Handler__c, Job__r.Next_Job__c,
                   Job__r.Processor__c, Job__r.Is_Active__c, Job__r.Application__c
            FROM Job_Trigger_Event__c
            WHERE Application__c = :application
            AND (Event_Key__c = :triggerEvent OR Trigger_Event__c = :triggerEvent)
            ORDER BY Is_Active__c DESC
            LIMIT 20
        ];
    }

    private static Job_Trigger_Event__c pickMapping(
            List<Job_Trigger_Event__c> mappings,
            String application) {
        if (mappings == null || mappings.isEmpty() || String.isBlank(application)) {
            return null;
        }
        String app = normalize(application);
        for (Job_Trigger_Event__c mapping : mappings) {
            if (normalize(mapping.Application__c) == app) return mapping;
        }
        return null;
    }

    private static void rememberJob(Job__c job) {
        if (job == null || job.Id == null) return;
        jobsById.put(job.Id, job);
        if (String.isNotBlank(job.Handler__c) && String.isNotBlank(job.Application__c)) {
            jobsByHandler.put(catalogKey(job.Application__c, job.Handler__c), job);
        }
    }

    private static void load() {
        jobsByHandler = new Map<String, Job__c>();
        jobsById = new Map<Id, Job__c>();
        for (Job__c job : [
            SELECT Id, Name, Handler__c, Next_Job__c, Processor__c, Is_Active__c, Application__c
            FROM Job__c
            WHERE Is_Active__c = true
        ]) {
            jobsById.put(job.Id, job);
            if (String.isNotBlank(job.Handler__c) && String.isNotBlank(job.Application__c)) {
                jobsByHandler.put(catalogKey(job.Application__c, job.Handler__c), job);
            }
        }
        headJobIdByEvent = new Map<String, Id>();
        for (Job_Trigger_Event__c mapping : [
            SELECT Event_Key__c, Trigger_Event__c, Job__c, Application__c
            FROM Job_Trigger_Event__c
            WHERE Is_Active__c = true
        ]) {
            indexMapping(mapping);
        }
    }

    /**
     * Queue Trigger_Event__c matches mapping Event_Key__c or Trigger_Event__c
     * only when Application on the mapping equals Application on the Job.
     */
    private static void indexMapping(Job_Trigger_Event__c mapping) {
        if (mapping.Job__c == null || !jobsById.containsKey(mapping.Job__c)) return;
        Job__c job = jobsById.get(mapping.Job__c);
        if (!sameApplication(mapping.Application__c, job.Application__c)) return;
        if (String.isBlank(mapping.Application__c)) return;
        indexEventAlias(mapping.Event_Key__c, mapping.Application__c, mapping.Job__c);
        indexEventAlias(mapping.Trigger_Event__c, mapping.Application__c, mapping.Job__c);
    }

    private static void indexEventAlias(String eventValue, String application, Id jobId) {
        String event = normalize(eventValue);
        if (String.isBlank(event) || String.isBlank(application)) return;
        headJobIdByEvent.put(catalogKey(application, event), jobId);
    }

    private static String catalogKey(String application, String triggerEvent) {
        return normalize(application) + '\n' + normalize(triggerEvent);
    }

    private static String normalize(String value) {
        return String.isBlank(value) ? null : value.trim().toLowerCase();
    }

    private static Boolean sameApplication(String left, String right) {
        String a = normalize(left);
        String b = normalize(right);
        return a != null && a == b;
    }

    private static void seedIfMissing() {
        Map<String, Job__c> existing = new Map<String, Job__c>();
        for (Job__c job : [
            SELECT Id, Name, Handler__c, Next_Job__c, Processor__c, Application__c
            FROM Job__c
        ]) {
            existing.put(job.Name, job);
        }

        List<Job__c> toInsert = new List<Job__c>();
        addSeedJob(toInsert, existing, HANDLER_SHARE_MAIN_DIRECT, PROCESSOR_QUEUEABLE);
        addSeedJob(toInsert, existing, HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS, PROCESSOR_QUEUEABLE);
        addSeedJob(toInsert, existing, HANDLER_SHARE_MAIN_TO_TEAM_MEMBERS, PROCESSOR_QUEUEABLE);
        addSeedJob(toInsert, existing, HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER, PROCESSOR_BATCH);
        addSeedJob(toInsert, existing, HANDLER_RECONCILE_MAIN, PROCESSOR_BATCH);
        if (!toInsert.isEmpty()) insert toInsert;
        for (Job__c job : toInsert) existing.put(job.Name, job);

        Job__c shareMain = existing.get(HANDLER_SHARE_MAIN_DIRECT);
        Job__c shareAll = existing.get(HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER);
        if (shareMain != null && shareAll != null && shareMain.Next_Job__c == null) {
            shareMain.Next_Job__c = shareAll.Id;
            update shareMain;
            existing.put(shareMain.Name, shareMain);
        }

        Job__c reconcile = existing.get(HANDLER_RECONCILE_MAIN);
        if (reconcile != null) {
            Boolean dirty = false;
            if (reconcile.Handler__c != HANDLER_RECONCILE_MAIN) {
                reconcile.Handler__c = HANDLER_RECONCILE_MAIN;
                dirty = true;
            }
            if (reconcile.Processor__c != PROCESSOR_BATCH) {
                reconcile.Processor__c = PROCESSOR_BATCH;
                dirty = true;
            }
            if (reconcile.Next_Job__c != null) {
                reconcile.Next_Job__c = null;
                dirty = true;
            }
            if (dirty) {
                update reconcile;
                existing.put(reconcile.Name, reconcile);
            }
        }

        Set<String> existingEvents = new Set<String>();
        for (Job_Trigger_Event__c mapping : [SELECT Event_Key__c FROM Job_Trigger_Event__c]) {
            existingEvents.add(mapping.Event_Key__c);
        }

        List<Job_Trigger_Event__c> mappings = new List<Job_Trigger_Event__c>();
        addMapping(mappings, existingEvents, existing,
            EVENT_TEAM_MEMBER_CREATED, EVENT_TEAM_MEMBER_CREATED, HANDLER_SHARE_MAIN_DIRECT);
        addMapping(mappings, existingEvents, existing,
            EVENT_TEAM_MEMBER_UPDATED, EVENT_TEAM_MEMBER_UPDATED, HANDLER_SHARE_MAIN_DIRECT);
        addMapping(mappings, existingEvents, existing,
            EVENT_RELATED_RECORD_CREATED, EVENT_RELATED_RECORD_CREATED,
            HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS);
        addMapping(mappings, existingEvents, existing,
            EVENT_TEAM_MEMBER_DELETED, EVENT_TEAM_MEMBER_DELETED, HANDLER_RECONCILE_MAIN);
        addMapping(mappings, existingEvents, existing,
            EVENT_RECONCILE_SWEEP, EVENT_RECONCILE_SWEEP, HANDLER_RECONCILE_MAIN);
        addMapping(mappings, existingEvents, existing,
            EVENT_MANUAL, EVENT_MANUAL, HANDLER_RECONCILE_MAIN);
        if (!mappings.isEmpty()) insert mappings;
    }

    private static void addSeedJob(
            List<Job__c> toInsert,
            Map<String, Job__c> existing,
            String handler,
            String processor) {
        if (existing.containsKey(handler)) return;
        toInsert.add(new Job__c(
            Name = handler,
            Handler__c = handler,
            Is_Active__c = true,
            Processor__c = processor,
            SOQL_Queries_Warning_Pct__c = 80,
            Query_Rows_Warning_Pct__c = 80,
            DML_Statements_Warning_Pct__c = 80,
            DML_Rows_Warning_Pct__c = 80,
            CPU_Time_Warning_Pct__c = 80
        ));
    }

    /**
     * Event_Key is the queue Trigger Event string (including values).
     * Trigger_Event on this object is the generic picklist (Created/Deleted/…).
     */
    private static void addMapping(
            List<Job_Trigger_Event__c> mappings,
            Set<String> existingEvents,
            Map<String, Job__c> jobs,
            String eventKey,
            String triggerEvent,
            String handler) {
        if (String.isBlank(eventKey) || existingEvents.contains(eventKey)) return;
        Job__c job = jobs.get(handler);
        if (job == null) return;
        mappings.add(new Job_Trigger_Event__c(
            Name = eventKey,
            Job__c = job.Id,
            Trigger_Event__c = triggerEvent,
            Event_Key__c = eventKey,
            Is_Active__c = true
        ));
        existingEvents.add(eventKey);
    }
}