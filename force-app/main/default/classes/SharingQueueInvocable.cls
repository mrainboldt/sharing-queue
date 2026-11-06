/**
 * @description Flow entry for Sharing Queue events. Replaces Create Records on
 * Sharing_Queue__c. Flows: Get Records → this action. No Decision for
 * queue on/off; Sharing_Queue_Setting__mdt Default.Use_Sharing_Queue__c
 * gates insert.
 *
 * Application and Trigger Event are Apex enums so Flow renders picklists.
 * Enum API values match Sharing_Queue__c picklists (OCC events map from
 * identifier names to dotted Event Keys such as OCC.LegalTeamMember.Created).
 * Object API names are derived from the Ids. Workers resolve user, access,
 * and related objects from config and the source record.
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueInvocable {

    public enum Application {
        Appeals,
        Matters,
        TEGE,
        Portals,
        Platform,
        TAS,
        OCC,
        GLS
    }

    public enum TriggerEvent {
        TeamMemberCreated,
        TeamMemberUpdated,
        TeamMemberDeleted,
        RelatedRecordCreated,
        ReconcileSweep,
        Manual,
        OCC_MatterRelatedRecord_Create,
        OCC_Legal_Team_Member_Created,
        OCC_Legal_Team_Member_Updated,
        OCC_Legal_Team_Member_Deleted,
        OCC_Legal_Team_Member_Start,
        OCC_Legal_Team_Member_End
    }

    /**
     * @description Flow input for one Sharing Queue event. Object API names are derived from the
     * Ids.
     * @author Melissa Rainboldt
     */
    public class Request {
        @InvocableVariable(required=true label='Application')
        public Application application;
        @InvocableVariable(required=true label='Trigger Event')
        public TriggerEvent triggerEvent;
        @InvocableVariable(required=true label='Main Record Id')
        public Id mainRecordId;
        @InvocableVariable(label='Source Record Id')
        public Id sourceRecordId;
    }

    /**
     * @description Flow output reporting how many Sharing Queue rows were inserted for the request.
     * @author Melissa Rainboldt
     */
    public class Result {
        @InvocableVariable(label='Records Enqueued')
        public Integer recordsEnqueued;
    }

    /**
     * @description Inserts event-only Sharing Queue rows when the queue is enabled. Returns a
     * result for each request.
     * @author Melissa Rainboldt
     * @param requests Invocable requests, one per Flow interview.
     * @return One result per request. recordsEnqueued is 0 when the queue is disabled or the
     * request is incomplete.
     */
    @InvocableMethod(
        label='Enqueue Sharing Queue Event'
        description='When Sharing Queue is enabled, inserts event-only Sharing Queue rows (Job blank). Catalog expand and workers run from Apex. When disabled, inserts nothing. Use instead of Flow Create Records on Sharing Queue.'
        category='Sharing'
    )
    public static List<Result> enqueue(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) return results;

        if (!SharingQueueSettings.useSharingQueue()) {
            for (Integer i = 0; i < requests.size(); i++) {
                Result result = new Result();
                result.recordsEnqueued = 0;
                results.add(result);
            }
            return results;
        }

        List<SharingQueueService.EventRequest> specs =
            new List<SharingQueueService.EventRequest>();
        for (Request request : requests) {
            SharingQueueService.EventRequest spec = new SharingQueueService.EventRequest();
            if (request != null) {
                spec.application = applicationApiName(request.application);
                spec.triggerEvent = triggerEventApiName(request.triggerEvent);
                spec.mainRecordId = request.mainRecordId;
                spec.sourceRecordId = request.sourceRecordId;
            }
            specs.add(spec);
        }

        List<Integer> counts = SharingQueueService.enqueueFromEventRequests(specs);
        for (Integer count : counts) {
            Result result = new Result();
            result.recordsEnqueued = count;
            results.add(result);
        }
        return results;
    }

    /**
     * @description Returns the Application picklist API name for the Flow enum.
     * @author Melissa Rainboldt
     * @param value Application enum value selected in Flow.
     * @return The Application enum name, or null when value is null.
     */
    @TestVisible
    static String applicationApiName(Application value) {
        return value == null ? null : value.name();
    }

    /**
     * @description Returns the Trigger Event picklist value for the Flow enum, including OCC values
     * that contain dots.
     * @author Melissa Rainboldt
     * @param value Trigger Event enum value selected in Flow.
     * @return The Trigger Event picklist API value, or null when value is null.
     */
    @TestVisible
    static String triggerEventApiName(TriggerEvent value) {
        if (value == null) return null;
        switch on value {
            when OCC_MatterRelatedRecord_Create {
                return 'OCC.MatterRelatedRecord.Create';
            }
            when OCC_Legal_Team_Member_Created {
                return JobCatalogService.EVENT_OCC_LTM_CREATED;
            }
            when OCC_Legal_Team_Member_Updated {
                return JobCatalogService.EVENT_OCC_LTM_UPDATED;
            }
            when OCC_Legal_Team_Member_Deleted {
                return JobCatalogService.EVENT_OCC_LTM_DELETED;
            }
            when OCC_Legal_Team_Member_Start {
                return JobCatalogService.EVENT_OCC_LTM_START;
            }
            when OCC_Legal_Team_Member_End {
                return JobCatalogService.EVENT_OCC_LTM_END;
            }
            when else {
                return value.name();
            }
        }
    }
}
