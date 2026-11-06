/**
 * @description Job__c.Handler__c API name must match a concrete subclass.
 * Job__c.Processor__c chooses which method the worker calls.
 *
 * Override process() for Queueable Jobs, processChunk() for Batch Jobs,
 * and the is* flags for compaction.
 *
 * Return values are share-row counts written onto Records_Processed__c,
 * not success/failure. Return 0 when there is nothing to share. Throw to fail.
 * @author Melissa Rainboldt
 */
public abstract class SharingQueueHandler {
    /**
     * @description Runs one Queueable row. The share-row count is written to Records Processed.
     * Throw to fail the row.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return The number of share rows written. 0 when there is nothing to share.
     */
    public virtual Integer process(Sharing_Queue__c queue) {
        throw new SharingConfigService.SharingException(
            'Handler does not support Queueable. Set Job Processor to Batch.');
    }

    /**
     * @description Runs one Batch scope. The share-row count is written to Records Processed. Throw
     * to fail the slice.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param children Child records in the current scope.
     * @return The number of share rows written for the chunk.
     */
    public virtual Integer processChunk(
            List<Sharing_Queue__c> queues,
            List<SObject> children) {
        throw new SharingConfigService.SharingException(
            'Handler does not support Batch. Set Job Processor to Queueable.');
    }

    /**
     * @description Returns whether compaction and the drain should treat this handler as one
     * related record shared to all team members.
     * @author Melissa Rainboldt
     * @return True when subclasses share one related record to all team members. The base returns
     * false.
     */
    public virtual Boolean isRelatedRecordJob() {
        return false;
    }

    /**
     * @description Returns whether compaction should treat this handler as one team member fanned
     * out to related records.
     * @author Melissa Rainboldt
     * @return True when subclasses fan one team member out to related records. The base returns
     * false.
     */
    public virtual Boolean isFanoutJob() {
        return false;
    }

    /**
     * @description Returns whether compaction should treat this handler as a full rebuild.
     * @author Melissa Rainboldt
     * @return True when subclasses rebuild every team member. The base returns false.
     */
    public virtual Boolean isReconcileJob() {
        return false;
    }

    /**
     * @description Queueable drain bulk-loads Team Members by Source Id for this handler.
     * ShareMainToTeamMembers stays per-row (all TMs on Main).
     * @author Melissa Rainboldt
     * @return True when the drain should bulk-load team members by source Id. The base returns
     * false.
     */
    public virtual Boolean isShareMainDirectJob() {
        return false;
    }

    /**
     * @description Queueable drain: collect share SObjects without DML so many rows share
     * one insertShares. Default false uses process() per queue.
     * @author Melissa Rainboldt
     * @return True when the drain should collect share sObjects and insert them once. The base
     * returns false.
     */
    public virtual Boolean collectsShares() {
        return false;
    }

    /**
     * @description Builds share rows without DML. The default throws because collectsShares is
     * false.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return Share sObjects to insert. The base throws because collectsShares is false.
     */
    public virtual List<SObject> collectShares(Sharing_Queue__c queue) {
        throw new SharingConfigService.SharingException(
            'Handler does not collect shares. Override collectsShares() or process().');
    }
}
