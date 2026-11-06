/**
 * @description Batch handler that rebuilds related-record shares for every active team member on
 * the main.
 * @author Melissa Rainboldt
 */
public virtual class ReconcileMain extends SharingQueueHandler {
    /**
     * @description Rebuilds shares for the child chunk across every active team member.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param children Child records in the current scope.
     * @return The number of share rows written for the chunk.
     */
    public override Integer processChunk(
            List<Sharing_Queue__c> queues,
            List<SObject> children) {
        return SharingQueueService.shareChildChunk(queues, children, true);
    }

    /**
     * @description Marks this handler as a reconcile job so compaction can subsume narrower work.
     * @author Melissa Rainboldt
     * @return True. Compaction treats this handler as a full rebuild.
     */
    public override Boolean isReconcileJob() {
        return true;
    }
}
