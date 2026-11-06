/**
 * @description Batch handler that shares related records to the team member named on the queue row.
 * @author Melissa Rainboldt
 */
public virtual class ShareAllRelatedToTeamMember extends SharingQueueHandler {
    /**
     * @description Shares the child chunk to the team member named on each queue row.
     * @author Melissa Rainboldt
     * @param queues Sharing Queue rows in this unit of work.
     * @param children Child records in the current scope.
     * @return The number of share rows written for the chunk.
     */
    public override Integer processChunk(
            List<Sharing_Queue__c> queues,
            List<SObject> children) {
        return SharingQueueService.shareChildChunk(queues, children, false);
    }

    /**
     * @description Marks this handler as a fan-out job so compaction can group it with
     * related-record work.
     * @author Melissa Rainboldt
     * @return True. Compaction treats this handler as fan-out work.
     */
    public override Boolean isFanoutJob() {
        return true;
    }
}
