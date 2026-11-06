/**
 * @description Sharing Queue volume engine: enqueue in run(), drain Queueable then Batch
 * in drainOnce() so VolumeHarness can count worker governors.
 * @author Melissa Rainboldt
 */
public class SharingQueueVolumeEngine extends VolumeEngine {
    public enum Op {
        TEAM_MEMBER_CREATED,
        TEAM_MEMBER_UPDATED,
        RELATED_CREATED,
        RELATED_UPDATED
    }

    private Op operation;
    private String application;
    private String objectApiName;
    private List<SObject> records;
    private Map<Id, SObject> oldMap;

    /**
     * @description Stores the volume operation that run enqueues onto the Sharing Queue.
     * @author Melissa Rainboldt
     * @param operation Volume scenario to enqueue, such as a team-member or related-record change.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @param objectApiName API name of the sObject.
     * @param records Source records for this operation.
     * @param oldMap Prior records keyed by Id. Null on insert.
     * @return A new SharingQueueVolumeEngine instance.
     */
    public SharingQueueVolumeEngine(
            Op operation,
            String application,
            String objectApiName,
            List<SObject> records,
            Map<Id, SObject> oldMap) {
        this.operation = operation;
        this.application = application;
        this.objectApiName = objectApiName;
        this.records = records;
        this.oldMap = oldMap;
    }

    /**
     * @description Returns the label VolumeHarness prints for the Sharing Queue path.
     * @author Melissa Rainboldt
     * @return SharingQueue.
     */
    public override String name() {
        return 'SharingQueue';
    }

    /**
     * @description Enqueues the volume operation onto the Sharing Queue.
     * @author Melissa Rainboldt
     * @return void
     */
    public override void run() {
        if (operation == Op.TEAM_MEMBER_CREATED) {
            SharingQueueService.enqueueFromTeamMembers(
                records,
                null,
                JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
                application);
        } else if (operation == Op.TEAM_MEMBER_UPDATED) {
            SharingQueueService.enqueueFromTeamMembers(
                records,
                oldMap,
                JobCatalogService.EVENT_TEAM_MEMBER_UPDATED,
                application);
        } else if (operation == Op.RELATED_CREATED || operation == Op.RELATED_UPDATED) {
            // RelatedRecordCreated is the only related catalog event today.
            SharingQueueService.enqueueFromRelatedRecords(
                objectApiName, records, application);
        }
    }

    /**
     * @description Runs one Queueable execute or one Batch slice synchronously. Returns false when
     * nothing is pending.
     * @author Melissa Rainboldt
     * @return True when a Queueable execute or Batch slice ran.
     */
    public override Boolean drainOnce() {
        SharingQueueService.suppressAsyncKick = true;
        try {
            if (hasPending(JobCatalogService.PROCESSOR_QUEUEABLE)) {
                new SharingQueueQueueable().execute(null);
                return true;
            }
            if (hasPending(JobCatalogService.PROCESSOR_BATCH)) {
                return SharingQueueBatch.drainOnePendingSlice();
            }
            return false;
        } finally {
            SharingQueueService.suppressAsyncKick = false;
        }
    }

    /**
     * @description Returns whether a Pending row exists for that processor.
     * @author Melissa Rainboldt
     * @param processor Job processor, Queueable or Batch.
     * @return True when at least one Pending row exists for the processor.
     */
    private static Boolean hasPending(String processor) {
        return [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Status__c = :SharingQueueService.STATUS_PENDING
            AND Job__c != null
            AND Job__r.Processor__c = :processor
            LIMIT 1
        ] > 0;
    }
}
