/**
 * @description Queueable handler that shares the main record with every active team member.
 * @author Melissa Rainboldt
 */
public virtual class ShareMainToTeamMembers extends SharingQueueHandler {
    /**
     * @description Tells the Queueable drain to collect share rows and insert them once.
     * @author Melissa Rainboldt
     * @return True. The drain collects shares instead of calling process per row.
     */
    public override Boolean collectsShares() {
        return true;
    }

    /**
     * @description Builds one main share per active team member, keeping the highest access for
     * each principal.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return One main share per principal. Empty when the main Id is missing or no team member
     * resolves.
     */
    public override List<SObject> collectShares(Sharing_Queue__c queue) {
        List<SObject> shares = new List<SObject>();
        SharingConfigService cfg = SharingConfigService.getInstance(queue.Application__c);
        Id mainId = SharingQueueService.toId(queue.Main_Record_Id__c);
        if (mainId == null) return shares;
        List<SObject> teamMembers = TeamMemberSharingService.queryTeamMembers(
            new Set<Id>{ mainId }, cfg);
        String rowCause = SharingQueueService.rowCauseForObject(
            cfg, queue.Main_Object_Api_Name__c);
        Map<Id, String> levelByPrincipal = new Map<Id, String>();
        for (SObject tm : teamMembers) {
            Id principalId = TeamMemberSharingService.userOrGroupId(tm, cfg.teamMemberConfig);
            if (principalId == null) continue;
            String shareLevel = SharingQueueService.resolveShareLevel(
                cfg,
                TeamMemberSharingService.stringValue(tm, cfg.teamMemberConfig.roleField),
                TeamMemberSharingService.stringValue(tm, cfg.teamMemberConfig.accessLevelField));
            if (String.isBlank(shareLevel)) continue;
            levelByPrincipal.put(
                principalId,
                TeamMemberSharingService.maxAccess(levelByPrincipal.get(principalId), shareLevel));
        }
        for (Id principalId : levelByPrincipal.keySet()) {
            SObject share = TeamMemberSharingService.buildShareRow(
                queue.Main_Object_Api_Name__c,
                mainId,
                principalId,
                levelByPrincipal.get(principalId),
                rowCause);
            if (share != null) shares.add(share);
        }
        return shares;
    }

    /**
     * @description Inserts main shares for every active team member. Returns 0 when there is
     * nothing to share.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return The number of share rows inserted. 0 when there is nothing to share.
     */
    public override Integer process(Sharing_Queue__c queue) {
        List<SObject> shares = collectShares(queue);
        if (shares.isEmpty()) return 0;
        return TeamMemberSharingService.insertShares(shares);
    }
}
