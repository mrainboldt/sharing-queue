/**
 * @description Queueable handler that inserts Apex shares for one related record and every active
 * team member. The parent on Sharing Object Config may be a lookup, a formula that stores the main
 * Id, or a relationship path. The child is queried so those fields are populated; formula fields
 * are not written.
 * @author Melissa Rainboldt
 */
public virtual class ShareRelatedToAllTeamMembers extends SharingQueueHandler {
    /**
     * @description Tells the Queueable drain to collect share rows and insert them once.
     * @author Melissa Rainboldt
     * @return True. The drain collects shares instead of calling process per row.
     */
    public override Boolean collectsShares() {
        return true;
    }

    /**
     * @description Builds shares for this related record and every active team member on its main.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return Shares for the related record and each active team member. Empty when the child or
     * config is missing.
     */
    public override List<SObject> collectShares(Sharing_Queue__c queue) {
        String objectApiName = SharingQueueService.relatedChildObjectApiName(queue);
        Id sourceId = SharingQueueService.toId(queue.Source_Record_Id__c);
        if (String.isBlank(objectApiName) || sourceId == null) return new List<SObject>();

        SharingConfigService cfg = SharingConfigService.getInstance(queue.Application__c);
        if (cfg.objectConfigByApiName.get(objectApiName.toLowerCase()) == null
                && cfg.configsForObject(objectApiName).isEmpty()) {
            return new List<SObject>();
        }

        List<SObject> children = cfg.queryRelatedRecords(
            objectApiName, new Set<Id>{ sourceId });
        if (children.isEmpty()) return new List<SObject>();

        return TeamMemberSharingService.buildSharesForNewChildRecords(
            new Map<String, List<SObject>>{
                objectApiName => children
            },
            queue.Application__c);
    }

    /**
     * @description Inserts those related-record shares. Returns 0 when there is nothing to share.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return The number of share rows inserted. 0 when there is nothing to share.
     */
    public override Integer process(Sharing_Queue__c queue) {
        List<SObject> shares = collectShares(queue);
        if (shares.isEmpty()) return 0;
        return TeamMemberSharingService.insertShares(shares);
    }

    /**
     * @description Marks this handler as a related-record job so the drain can bulk-query children.
     * @author Melissa Rainboldt
     * @return True. Compaction and the drain treat this as a related-record job.
     */
    public override Boolean isRelatedRecordJob() {
        return true;
    }
}
