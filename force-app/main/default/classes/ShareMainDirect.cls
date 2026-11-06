/**
 * @description Queueable handler that inserts one Apex-managed share on the main record for a
 * single team member.
 * @author Melissa Rainboldt
 */
public virtual class ShareMainDirect extends SharingQueueHandler {
    /**
     * @description Tells the Queueable drain to collect share rows and insert them once.
     * @author Melissa Rainboldt
     * @return True. The drain collects shares instead of calling process per row.
     */
    public override Boolean collectsShares() {
        return true;
    }

    /**
     * @description Marks this handler so the drain bulk-loads team members by source Id.
     * @author Melissa Rainboldt
     * @return True. The drain bulk-loads team members by source Id.
     */
    public override Boolean isShareMainDirectJob() {
        return true;
    }

    /**
     * @description Builds the main share for this queue from the source team member.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @return Main share rows for the queue. Empty when the principal or access level cannot be
     * resolved.
     */
    public override List<SObject> collectShares(Sharing_Queue__c queue) {
        SharingConfigService cfg = SharingConfigService.getInstance(queue.Application__c);
        Id sourceId = SharingQueueService.toId(queue.Source_Record_Id__c);
        Set<Id> sourceIds = sourceId == null ? new Set<Id>() : new Set<Id>{ sourceId };
        Map<Id, SObject> byId = TeamMemberSharingService.queryTeamMembersByIds(sourceIds, cfg);
        return sharesForQueue(queue, byId.get(sourceId), null);
    }

    /**
     * @description Inserts the main share for this queue. Returns 0 when there is nothing to share.
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
     * @description Build the Main share for one queue from a preloaded Team Member.
     * teamMembersByMain non-null: RAP fallback uses that map (no extra SOQL).
     * Null: maxMainAccessForPrincipal queries active TMs on that Main.
     * @author Melissa Rainboldt
     * @param queue Sharing Queue row to process.
     * @param teamMember Team member sObject. Null when only the payload is available.
     * @param teamMembersByMain Active team members keyed by main Id. Null queries them instead.
     * @return Main share rows for the queue. Empty when the principal or access level cannot be
     * resolved.
     */
    public static List<SObject> sharesForQueue(
            Sharing_Queue__c queue,
            SObject teamMember,
            Map<Id, List<SObject>> teamMembersByMain) {
        List<SObject> shares = new List<SObject>();
        if (queue == null) return shares;
        Id mainId = SharingQueueService.toId(queue.Main_Record_Id__c);
        if (mainId == null) return shares;

        SharingConfigService cfg = SharingConfigService.getInstance(queue.Application__c);
        SharingQueueService.Payload payload = SharingQueueService.parsePayload(queue.Payload__c);
        Id principalId = principalIdFor(cfg, teamMember, payload);
        if (principalId == null) {
            System.debug(LoggingLevel.INFO,
                'ShareMainDirect skipped: no User/Group on Team Member or payload');
            return shares;
        }

        String shareLevel = shareLevelFor(
            cfg, teamMember, payload, mainId, principalId, teamMembersByMain);
        if (String.isBlank(shareLevel)) {
            System.debug(LoggingLevel.INFO, 'ShareMainDirect skipped: no share access level for Main '
                + queue.Main_Object_Api_Name__c);
            return shares;
        }
        if (shareLevel == 'All') {
            shareLevel = 'Edit';
        }

        String rowCause = SharingQueueService.rowCauseForObject(
            cfg, queue.Main_Object_Api_Name__c);
        SObject share = TeamMemberSharingService.buildShareRow(
            queue.Main_Object_Api_Name__c,
            mainId,
            principalId,
            shareLevel,
            rowCause);
        if (share != null) shares.add(share);
        return shares;
    }

    /**
     * @description Resolves the user or group from the team member, then from the payload.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param teamMember Team member sObject. Null when only the payload is available.
     * @param payload Queue payload carrying principal, access, related objects, and cursor.
     * @return The user or group Id, or null when neither the team member nor the payload has one.
     */
    public static Id principalIdFor(
            SharingConfigService cfg,
            SObject teamMember,
            SharingQueueService.Payload payload) {
        Id principalId = teamMember == null || cfg == null
            ? null
            : TeamMemberSharingService.userOrGroupId(teamMember, cfg.teamMemberConfig);
        if (principalId == null && payload != null) {
            principalId = SharingQueueService.toId(payload.userOrGroupId);
        }
        return principalId;
    }

    /**
     * @description Resolves main access from the team member, the payload, or the highest access
     * that principal already has on the main.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param teamMember Team member sObject. Null when only the payload is available.
     * @param payload Queue payload carrying principal, access, related objects, and cursor.
     * @param mainId Main record that would receive the share.
     * @param principalId User or group that would receive the share.
     * @param teamMembersByMain Active team members keyed by main Id. Null queries them instead.
     * @return The share access level, or null when it cannot be resolved.
     */
    public static String shareLevelFor(
            SharingConfigService cfg,
            SObject teamMember,
            SharingQueueService.Payload payload,
            Id mainId,
            Id principalId,
            Map<Id, List<SObject>> teamMembersByMain) {
        if (teamMember != null && cfg != null && cfg.teamMemberConfig != null) {
            String fromMember = SharingQueueService.resolveShareLevel(
                cfg,
                TeamMemberSharingService.stringValue(teamMember, cfg.teamMemberConfig.roleField),
                TeamMemberSharingService.stringValue(teamMember, cfg.teamMemberConfig.accessLevelField));
            if (String.isNotBlank(fromMember)) return fromMember;
        }
        if (payload != null && String.isNotBlank(payload.accessLevel)) {
            String fromPayload = SharingConfigService.normalizeShareLevel(payload.accessLevel);
            return String.isNotBlank(fromPayload) ? fromPayload : payload.accessLevel;
        }
        if (teamMembersByMain != null) {
            return maxMainAccessFrom(cfg, principalId, teamMembersByMain.get(mainId));
        }
        return maxMainAccessForPrincipal(cfg, mainId, principalId);
    }

    /**
     * @description Queries active team members on the main and returns that principal's highest
     * access.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param mainId Main record Id.
     * @param principalId User or group that receives the share.
     * @return The principal's highest main access, or null.
     */
    private static String maxMainAccessForPrincipal(
            SharingConfigService cfg,
            Id mainId,
            Id principalId) {
        if (mainId == null || principalId == null || cfg == null) return null;
        return maxMainAccessFrom(
            cfg,
            principalId,
            TeamMemberSharingService.queryTeamMembers(new Set<Id>{ mainId }, cfg));
    }

    /**
     * @description Returns the principal's highest access among the loaded team members.
     * @author Melissa Rainboldt
     * @param cfg Sharing configuration for the application.
     * @param principalId User or group that receives the share.
     * @param teamMembers Team member records to evaluate.
     * @return The principal's highest access among the loaded team members, or null.
     */
    private static String maxMainAccessFrom(
            SharingConfigService cfg,
            Id principalId,
            List<SObject> teamMembers) {
        if (cfg == null || principalId == null || teamMembers == null) return null;
        String best;
        for (SObject tm : teamMembers) {
            if (TeamMemberSharingService.userOrGroupId(tm, cfg.teamMemberConfig) != principalId) {
                continue;
            }
            String candidate = SharingQueueService.resolveShareLevel(
                cfg,
                TeamMemberSharingService.stringValue(tm, cfg.teamMemberConfig.roleField),
                TeamMemberSharingService.stringValue(tm, cfg.teamMemberConfig.accessLevelField));
            best = TeamMemberSharingService.maxAccess(best, candidate);
        }
        return best;
    }
}
