/**
 * @description Core engine for Apex-managed `__Share` rows. Sharing Queue handlers
 * and Batch workers call these methods. Large child volumes belong on
 * SharingQueueBatch (QueryLocator), not inline recalculateForParents.
 *
 * insertShares() chunks its DML list into DML_CHUNK_SIZE slices for heap safety
 * — this does NOT increase the 10,000 row ceiling, it just avoids building a
 * single massive list before the first flush.
 * @author Melissa Rainboldt
 */
public without sharing class TeamMemberSharingService {

    // Heap-safety chunk for DML statements — NOT a workaround for the 10k row limit.
    // Each execute() transaction still counts all rows toward the 10k ceiling.
    @TestVisible
    static final Integer DML_CHUNK_SIZE = 2000;

    //Entry points───

    /**
     * @description Called when team member records change (role / accessLevel / active).
     * Safe for small parent sets where child volumes are limited.
     * For large data volumes enqueue Reconcile / fan-out so SharingQueueBatch walks children.
     * @author Melissa Rainboldt
     * @param parentIds Parent record IDs whose team members changed
     * @param affectedUserIds Users to rebuild (null = all users for the parents)
     * @param application Product whose Team Member / object config to use
     * @return void
     */
    public static void recalculateForParents(
            Set<Id> parentIds,
            Set<Id> affectedUserIds,
            String application) {
        if (parentIds == null || parentIds.isEmpty()) return;

        SharingConfigService cfg = SharingConfigService.getInstance(application);
        if (cfg.objectConfigs.isEmpty()) return;

        deleteShareRecords(parentIds, affectedUserIds, cfg);
        insertShares(buildShareRecords(parentIds, cfg));
    }

    /**
     * @description Called when new child records are inserted (trigger path).
     * Safe for trigger-sized batches (up to ~200 records × team members per parent).
     * For bulk-loaded child records enqueue RelatedRecordCreated so Sharing Queue workers share.
     * @author Melissa Rainboldt
     * @param childRecordsByObject Map<childObjectApiName, List<SObject>> of new records
     * @param application Product whose Team Member / object config to use
     * @return number of share rows inserted (after collapsing duplicates)
     */
    public static Integer recalculateForNewChildRecords(
            Map<String, List<SObject>> childRecordsByObject,
            String application) {
        List<SObject> shares = buildSharesForNewChildRecords(childRecordsByObject, application);
        if (shares.isEmpty()) return 0;
        return insertShares(shares);
    }

    /**
     * @description Builds Apex share rows for new related records without DML. Used by
     * ShareRelatedToAllTeamMembers so the Queueable drain can insert once.
     * @author Melissa Rainboldt
     * @param childRecordsByObject New child records keyed by object API name.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return Share rows for the new children. Empty when no team member resolves.
     */
    public static List<SObject> buildSharesForNewChildRecords(
            Map<String, List<SObject>> childRecordsByObject,
            String application) {
        List<SObject> sharesToInsert = new List<SObject>();
        if (childRecordsByObject == null || childRecordsByObject.isEmpty())
        {
            System.debug(LoggingLevel.INFO, 'TeamMemberSharingService.buildSharesForNewChildRecords called with empty childRecordsByObject');
            return sharesToInsert;
        }

        SharingConfigService cfg = SharingConfigService.getInstance(application);

        Map<String, List<SObject>> hydrated = new Map<String, List<SObject>>();
        for (String objApiName : childRecordsByObject.keySet()) {
            hydrated.put(
                objApiName,
                cfg.hydrateRelatedRecords(objApiName, childRecordsByObject.get(objApiName)));
        }
        childRecordsByObject = hydrated;

        Set<Id> parentIds = new Set<Id>();
        for (String objApiName : childRecordsByObject.keySet()) {
            SharingConfigService.ObjectConfig oc = cfg.objectConfigByApiName.get(objApiName.toLowerCase());
            if (oc == null)
            {
                System.debug(LoggingLevel.INFO, 'No ObjectConfig found for child object: ' + objApiName + ' in application: ' + application);
                continue;
            }
            for (SObject rec : childRecordsByObject.get(objApiName)) {
                parentIds.addAll(oc.parentIdsOn(rec));
            }
        }
        if (parentIds.isEmpty())
        {
            System.debug(LoggingLevel.INFO, 'No parent IDs found for child records in application: ' + application);
            return sharesToInsert;
        }

        List<SObject> teamMembers = queryTeamMembers(parentIds, cfg);
        if (teamMembers.isEmpty()){
            System.debug(LoggingLevel.INFO, 'No active team members found for parent IDs: ' + String.join(new List<Id>(parentIds), ', ') + ' in application: ' + application);
            return sharesToInsert;
        }

        for (String objApiName : childRecordsByObject.keySet()) {
            List<SharingConfigService.ObjectConfig> slices = cfg.configsForObject(objApiName);
            if (slices.isEmpty()) continue;
            List<SObject> incoming = childRecordsByObject.get(objApiName);
            Set<Id> incomingIds = new Set<Id>();
            for (SObject rec : incoming) {
                if (rec.get('Id') != null) incomingIds.add((Id) rec.get('Id'));
            }
            Map<Id, SObject> incomingById = new Map<Id, SObject>();
            for (SObject rec : incoming) {
                if (rec.get('Id') != null) incomingById.put((Id) rec.get('Id'), rec);
            }

            for (SharingConfigService.ObjectConfig oc : slices) {
                Set<Id> inSlice = oc.matchingIds(incomingIds);
                if (inSlice.isEmpty())
                {
                    System.debug(LoggingLevel.INFO, 'No matching child records found for ObjectConfig: ' + oc.childObjectApiName + ' in application: ' + application);
                    continue;
                }

                Map<Id, Map<Id, String>> levelByParent = maxShareLevelByParentAndPrincipal(
                    teamMembers, cfg, oc);
                for (Id childId : inSlice) {
                    SObject rec = incomingById.get(childId);
                    if (rec == null)
                    {
                        System.debug(LoggingLevel.INFO, 'No SObject found for childId: ' + childId + ' in ObjectConfig: ' + oc.childObjectApiName + ' in application: ' + application);
                        continue;
                    }
                    for (Id parentId : oc.parentIdsOn(rec)) {
                        Map<Id, String> byPrincipal = levelByParent.get(parentId);
                        if (byPrincipal == null)
                        {
                            System.debug(LoggingLevel.INFO, 'No team members found for parentId: ' + parentId + ' in ObjectConfig: ' + oc.childObjectApiName + ' in application: ' + application);
                            continue;
                        }
                        for (Id principalId : byPrincipal.keySet()) {
                            addShare(sharesToInsert, buildShare(
                                oc, childId, principalId, byPrincipal.get(principalId)));
                        }
                    }
                }
            }
        }
        return sharesToInsert;
    }

    // Query helpers used by handlers and SharingQueueBatch ───────────────

    /**
     * @description Queries active team members for a set of parent IDs.
     * Public so Queueable/Batch handlers can reuse without duplication.
     * @author Melissa Rainboldt
     * @param parentIds Parent record Ids whose sharing is in scope.
     * @param cfg Sharing configuration for the application.
     * @return Active team members for the parents.
     */
    public static List<SObject> queryTeamMembers(Set<Id> parentIds, SharingConfigService cfg) {
        SharingConfigService.TeamMemberConfig tmc = cfg.teamMemberConfig;
        if (String.isBlank(tmc.objectApiName) || String.isBlank(tmc.parentLookupField)) {
            throw new SharingConfigService.SharingException(
                'Team_Member_Config__c is missing Team Member Object API Name or Parent Lookup Field API Name.');
        }
        if (String.isBlank(tmc.userField) && String.isBlank(tmc.groupField)) {
            throw new SharingConfigService.SharingException(
                'Team_Member_Config__c needs User Field API Name and/or Group Field API Name.');
        }

        List<String> selectFields = new List<String>{ 'Id', tmc.parentLookupField };
        if (String.isNotBlank(tmc.userField)) selectFields.add(tmc.userField);
        if (String.isNotBlank(tmc.groupField)) selectFields.add(tmc.groupField);
        if (String.isNotBlank(tmc.roleField)) selectFields.add(tmc.roleField);
        if (String.isNotBlank(tmc.accessLevelField)) selectFields.add(tmc.accessLevelField);

        String q = 'SELECT ' + String.join(selectFields, ', ')
            + ' FROM ' + tmc.objectApiName
            + ' WHERE ' + tmc.parentLookupField + ' IN :parentIds';

        if (String.isNotBlank(tmc.activeField)) {
            q += ' AND ' + tmc.activeField + ' = true';
        }

        return Database.query(q);
    }

    /**
     * @description Loads Team Members by Id. Used by ShareMainDirect so a newly created
     * row is found even when Active is not true yet (date formulas, same txn).
     * Does not apply the Active filter. Empty or unknown Ids yield an empty map.
     * @author Melissa Rainboldt
     * @param teamMemberIds Team member Ids to load, including inactive rows.
     * @param cfg Sharing configuration for the application.
     * @return Team members for the Ids, including rows that are not active.
     */
    public static Map<Id, SObject> queryTeamMembersByIds(
            Set<Id> teamMemberIds, SharingConfigService cfg) {
        Map<Id, SObject> byId = new Map<Id, SObject>();
        if (teamMemberIds == null || teamMemberIds.isEmpty()
                || cfg == null || cfg.teamMemberConfig == null) {
            return byId;
        }
        SharingConfigService.TeamMemberConfig tmc = cfg.teamMemberConfig;
        if (String.isBlank(tmc.objectApiName)) return byId;

        List<String> selectFields = new List<String>{ 'Id' };
        if (String.isNotBlank(tmc.parentLookupField)) selectFields.add(tmc.parentLookupField);
        if (String.isNotBlank(tmc.userField)) selectFields.add(tmc.userField);
        if (String.isNotBlank(tmc.groupField)) selectFields.add(tmc.groupField);
        if (String.isNotBlank(tmc.roleField)) selectFields.add(tmc.roleField);
        if (String.isNotBlank(tmc.accessLevelField)) selectFields.add(tmc.accessLevelField);

        String q = 'SELECT ' + String.join(selectFields, ', ')
            + ' FROM ' + tmc.objectApiName
            + ' WHERE Id IN :teamMemberIds';
        try {
            for (SObject row : Database.query(q)) {
                byId.put(row.Id, row);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.INFO, 'queryTeamMembersByIds skipped: ' + e.getMessage());
        }
        return byId;
    }

    /**
     * @description Loads one Team Member by Id. Wrapper over queryTeamMembersByIds.
     * @author Melissa Rainboldt
     * @param teamMemberId Team member Id to load.
     * @param cfg Sharing configuration for the application.
     * @return The team member, or null when the Id is unknown.
     */
    public static SObject queryTeamMemberById(Id teamMemberId, SharingConfigService cfg) {
        if (teamMemberId == null) return null;
        return queryTeamMembersByIds(new Set<Id>{ teamMemberId }, cfg).get(teamMemberId);
    }

    /**
     * @description Inserts one Apex-managed share row on any object (Main or child).
     * Returns 1 when a row was submitted, 0 when skipped (missing type/level/user).
     * Duplicate ParentId+UserOrGroupId+RowCause rows keep the highest AccessLevel;
     * an existing share is updated when this batch's level differs.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @param recordId Id stored as ParentId on the share.
     * @param userOrGroupId User or group Id on the share.
     * @param accessLevel Share or team-member access level.
     * @param rowCause Apex sharing reason stored on the share.
     * @return 1 when a share was submitted, 0 when it was skipped.
     */
    public static Integer insertShareRow(
            String objectApiName,
            Id recordId,
            Id userOrGroupId,
            String accessLevel,
            String rowCause) {
        if (recordId == null || userOrGroupId == null
                || String.isBlank(objectApiName)
                || String.isBlank(accessLevel)
                || String.isBlank(rowCause)) {
            System.debug(LoggingLevel.INFO, 'insertShareRow skipped: missing required parameters. objectApiName=' + objectApiName
                + ', recordId=' + recordId
                + ', userOrGroupId=' + userOrGroupId
                + ', accessLevel=' + accessLevel
                + ', rowCause=' + rowCause);
            return 0;
        }
        SObject share = buildShareRow(
            objectApiName, recordId, userOrGroupId, accessLevel, rowCause);
        if (share == null) return 0;
        insertShares(new List<SObject>{ share });
        return 1;
    }

    /**
     * @description Builds one Apex share SObject without DML. Null when skipped (OWD, missing
     * type).
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @param recordId Id stored as ParentId on the share.
     * @param userOrGroupId User or group Id on the share.
     * @param accessLevel Share or team-member access level.
     * @param rowCause Apex sharing reason stored on the share.
     * @return The share sObject, or null when it was skipped.
     */
    public static SObject buildShareRow(
            String objectApiName,
            Id recordId,
            Id userOrGroupId,
            String accessLevel,
            String rowCause) {
        if (recordId == null || userOrGroupId == null
                || String.isBlank(objectApiName)
                || String.isBlank(accessLevel)
                || String.isBlank(rowCause)) {
            System.debug(LoggingLevel.INFO, 'buildShareRow skipped: missing required parameters. objectApiName=' + objectApiName
                + ', recordId=' + recordId
                + ', userOrGroupId=' + userOrGroupId
                + ', accessLevel=' + accessLevel
                + ', rowCause=' + rowCause);
            return null;
        }
        if (SharingConfigService.owdAlreadyGrants(objectApiName, accessLevel)) {
            System.debug(LoggingLevel.INFO, 'buildShareRow skipped: OWD already grants '
                + accessLevel + ' on ' + objectApiName);
            return null;
        }
        String shareApi = SharingConfigService.deriveShareObjectName(objectApiName);
        Type shareType = Type.forName(shareApi);
        if (shareType == null) {
            System.debug(LoggingLevel.WARN, 'No share object found for: ' + objectApiName);
            return null;
        }
        SObject share = (SObject) shareType.newInstance();
        share.put('ParentId', recordId);
        share.put('UserOrGroupId', userOrGroupId);
        share.put('AccessLevel', accessLevel);
        share.put('RowCause', rowCause);
        return share;
    }

    /**
     * @description Partial share-insert result. Fatal errors are keyed so one bad share does not
     * fail the whole drain.
     * @author Melissa Rainboldt
     */
    public class ShareDmlOutcome {
        public Integer attempted = 0;
        public List<String> fatalMessages = new List<String>();
        public Map<String, String> fatalByShareKey = new Map<String, String>();
        /**
         * @description Returns whether any share failed for a reason other than an empty result.
         * @author Melissa Rainboldt
         * @return True when fatalByShareKey or fatalMessages is not empty.
         */
        public Boolean hasFatal() {
            return !fatalMessages.isEmpty();
        }
    }

    /**
     * @description Duplicate ParentId+UserOrGroupId+RowCause rows keep the highest AccessLevel.
     * If a share already exists, AccessLevel is updated to this batch's level.
     * DUPLICATE_VALUE is not a failure. Any other insert/update error is logged
     * then thrown so Sharing Queue workers markFailed.
     * @author Melissa Rainboldt
     * @param shares Share sObjects to insert, update, delete, or inspect.
     * @return The number of share rows submitted.
     */
    public static Integer insertShares(List<SObject> shares) {
        ShareDmlOutcome outcome = insertSharesPartial(shares);
        throwIfShareDmlFailed('insert', outcome.fatalMessages);
        return outcome.attempted;
    }

    /**
     * @description Same DML as insertShares but does not throw. Callers map fatalByShareKey
     * back to queue rows so one failed share does not fail the whole drain.
     * @author Melissa Rainboldt
     * @param shares Share sObjects to insert, update, delete, or inspect.
     * @return Inserted, duplicate, and fatal results for the batch.
     */
    public static ShareDmlOutcome insertSharesPartial(List<SObject> shares) {
        ShareDmlOutcome outcome = new ShareDmlOutcome();
        if (shares == null || shares.isEmpty()) {
            System.debug(LoggingLevel.INFO, 'insertShares called with empty shares list');
            return outcome;
        }

        List<SObject> collapsed = collapseToMaxAccess(shares);
        outcome.attempted = collapsed.size();
        List<Database.SaveResult> results = Database.insert(collapsed, false);
        List<SObject> duplicates = new List<SObject>();
        List<Error_Log__c> errorLogs = new List<Error_Log__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) continue;
            errorLogs.add(ErrorUtil.logError(results[i], false));
            Boolean duplicate = false;
            for (Database.Error err : results[i].getErrors()) {
                if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                    duplicate = true;
                } else {
                    String message = shareDmlError(collapsed[i], err);
                    outcome.fatalMessages.add(message);
                    String key = shareRowKey(collapsed[i]);
                    if (String.isNotBlank(key) && !outcome.fatalByShareKey.containsKey(key)) {
                        outcome.fatalByShareKey.put(key, message);
                    }
                }
            }
            if (duplicate) duplicates.add(collapsed[i]);
        }
        persistErrorLogs(errorLogs);
        updateExistingShares(duplicates);
        return outcome;
    }

    /**
     * @description All > Edit > Read. Blank loses. Used when one User/Group has several
     * Team Member rows on the same Main.
     * @author Melissa Rainboldt
     * @param first One access level. Blank loses to a ranked level.
     * @param second The other access level.
     * @return The higher access level. Blank loses to any ranked level.
     */
    public static String maxAccess(String first, String second) {
        return accessRank(first) >= accessRank(second) ? first : second;
    }

    /**
     * @description Highest mapped share level per parent + User/Group for one slice.
     * @author Melissa Rainboldt
     * @param teamMembers Team member records to evaluate.
     * @param cfg Sharing configuration for the application.
     * @param childObjectApiName API name of the related child object.
     * @return Parent Id to principal Id to the highest share level.
     */
    public static Map<Id, Map<Id, String>> maxShareLevelByParentAndPrincipal(
            List<SObject> teamMembers,
            SharingConfigService cfg,
            String childObjectApiName) {
        SharingConfigService.ObjectConfig oc = cfg == null || String.isBlank(childObjectApiName)
            ? null
            : cfg.objectConfigByApiName.get(childObjectApiName.toLowerCase());
        return maxShareLevelByParentAndPrincipal(teamMembers, cfg, oc);
    }

    /**
     * @description Maps each parent and principal to the highest share level for the slice.
     * @author Melissa Rainboldt
     * @param teamMembers Team member records to evaluate.
     * @param cfg Sharing configuration for the application.
     * @param oc Sharing object configuration slice.
     * @return Parent Id to principal Id to the highest share level.
     */
    public static Map<Id, Map<Id, String>> maxShareLevelByParentAndPrincipal(List<SObject> teamMembers
                                                                            , SharingConfigService cfg
                                                                            , SharingConfigService.ObjectConfig oc) 
    {
        Map<Id, Map<Id, String>> byParent = new Map<Id, Map<Id, String>>();
        if (teamMembers == null || cfg == null || cfg.teamMemberConfig == null || oc == null) {
            System.debug(LoggingLevel.INFO, 'maxShareLevelByParentAndPrincipal skipped: one or more parameters are null');
            return byParent;
        }
        SharingConfigService.TeamMemberConfig tmc = cfg.teamMemberConfig;
        for (SObject tm : teamMembers) {
            Id parentId = idValue(tm, tmc.parentLookupField);
            Id principalId = userOrGroupId(tm, tmc);
            if (parentId == null || principalId == null)
            {
                System.debug(LoggingLevel.INFO, 'Skipping team member record with missing parent or principal. TeamMemberId=' + tm.get('Id')
                    + ', ParentId=' + parentId
                    + ', PrincipalId=' + principalId);
                continue;
            }
            String shareLevel = cfg.getShareAccessLevel(
                stringValue(tm, tmc.roleField),
                stringValue(tm, tmc.accessLevelField),
                oc);
            if (String.isBlank(shareLevel))
            {
                System.debug(LoggingLevel.INFO, 'Skipping team member record with no share level. TeamMemberId=' + tm.get('Id')
                    + ', ParentId=' + parentId
                    + ', PrincipalId=' + principalId
                    + ', Role=' + stringValue(tm, tmc.roleField)
                    + ', AccessLevel=' + stringValue(tm, tmc.accessLevelField));
                continue;
            }
            if (!byParent.containsKey(parentId)) {
                byParent.put(parentId, new Map<Id, String>());
            }
            Map<Id, String> byPrincipal = byParent.get(parentId);
            byPrincipal.put(principalId, maxAccess(byPrincipal.get(principalId), shareLevel));
        }
        return byParent;
    }

    /**
     * @description Ranks access for comparisons. All is 3, Edit is 2, Read is 1, and blank is 0.
     * @author Melissa Rainboldt
     * @param level Access level to rank.
     * @return 3 for All, 2 for Edit, 1 for Read, and 0 for blank or unknown.
     */
    @TestVisible
    static Integer accessRank(String level) {
        if (String.isBlank(level)) return 0;
        String normalized = level.trim().toLowerCase();
        if (normalized == 'all') return 3;
        if (normalized == 'edit') return 2;
        if (normalized == 'read') return 1;
        return 0;
    }

    /**
     * @description Keeps one share per parent, user, and row cause, at the highest access level.
     * @author Melissa Rainboldt
     * @param shares Share sObjects to insert, update, delete, or inspect.
     * @return The collapsed share rows.
     */
    @TestVisible
    static List<SObject> collapseToMaxAccess(List<SObject> shares) {
        Map<String, SObject> byKey = new Map<String, SObject>();
        if (shares == null) return new List<SObject>();
        for (SObject share : shares) {
            if (share == null) continue;
            String key = shareKey(share);
            if (String.isBlank(key)) continue;
            SObject existing = byKey.get(key);
            if (existing == null
                    || accessRank((String) share.get('AccessLevel'))
                        > accessRank((String) existing.get('AccessLevel'))) {
                byKey.put(key, share);
            }
        }
        return byKey.values();
    }

    //Private helpers

    /**
     * @description Share principal for a team member row: User lookup if populated, else Group.
     * @author Melissa Rainboldt
     * @param teamMember Team member sObject. Null when only the payload is available.
     * @param tmc Team member field mapping for the application.
     * @return The user Id when populated, otherwise the group Id.
     */
    public static Id userOrGroupId(SObject teamMember, SharingConfigService.TeamMemberConfig tmc) {
        Id userId = idValue(teamMember, tmc == null ? null : tmc.userField);
        if (userId != null) return userId;
        return idValue(teamMember, tmc == null ? null : tmc.groupField);
    }

    /**
     * @description Reads an Id field. Returns null when the record or field name is missing.
     * @author Melissa Rainboldt
     * @param rec Current sObject.
     * @param fieldApi API name of the field to read or compare.
     * @return The Id, or null.
     */
    public static Id idValue(SObject rec, String fieldApi) {
        if (rec == null || String.isBlank(fieldApi)) return null;
        return (Id) rec.get(fieldApi);
    }

    /**
     * @description Reads a string field. Returns null when the record or field name is missing.
     * @author Melissa Rainboldt
     * @param rec Current sObject.
     * @param fieldApi API name of the field to read or compare.
     * @return The string value, or null.
     */
    public static String stringValue(SObject rec, String fieldApi) {
        if (rec == null || String.isBlank(fieldApi)) return null;
        return (String) rec.get(fieldApi);
    }

    /**
     * @description Deletes engine-owned shares for the parents' children.
     * @author Melissa Rainboldt
     * @param parentIds Parent record Ids whose sharing is in scope.
     * @param affectedUserIds Users to rebuild. Null rebuilds every principal on the parents.
     * @param cfg Sharing configuration for the application.
     * @return void
     */
    private static void deleteShareRecords(
            Set<Id> parentIds,
            Set<Id> affectedUserIds,
            SharingConfigService cfg) {

        for (SharingConfigService.ObjectConfig oc : cfg.objectConfigs) {
            Set<Id> childIds = queryChildIds(oc, parentIds);
            if (childIds.isEmpty())
            {
                System.debug(LoggingLevel.INFO, 'No child records found for ObjectConfig: ' + oc.childObjectApiName + ' in application: ' + cfg.application);
                continue;
            }

            String q = 'SELECT Id FROM ' + oc.shareObjectApiName
                + ' WHERE ParentId IN :childIds'
                + ' AND RowCause = \'' + oc.rowCause + '\'';

            if (affectedUserIds != null && !affectedUserIds.isEmpty()) {
                q += ' AND UserOrGroupId IN :affectedUserIds';
            }

            deleteShares(Database.query(q));
        }
    }

    /**
     * @description Builds the share rows implied by active team members on the parents.
     * @author Melissa Rainboldt
     * @param parentIds Parent record Ids whose sharing is in scope.
     * @param cfg Sharing configuration for the application.
     * @return Share rows to insert for the parents.
     */
    private static List<SObject> buildShareRecords(Set<Id> parentIds, SharingConfigService cfg) {
        List<SObject> teamMembers = queryTeamMembers(parentIds, cfg);
        if (teamMembers.isEmpty())
        {
            System.debug(LoggingLevel.INFO, 'No active team members found for parent IDs: ' + String.join(new List<Id>(parentIds), ', ') + ' in application: ' + cfg.application);
            return new List<SObject>();
        } 

        List<SObject> shares = new List<SObject>();
        for (SharingConfigService.ObjectConfig oc : cfg.objectConfigs) {
            Map<Id, Map<Id, String>> levelByParent = maxShareLevelByParentAndPrincipal(
                teamMembers, cfg, oc);
            String childQuery = 'SELECT Id, ' + oc.selectParentFields()
                + ' FROM ' + oc.childObjectApiName
                + ' WHERE ' + oc.whereParentIn('parentIds')
                + oc.andFilterClause();

            for (SObject child : Database.query(childQuery)) {
                for (Id parentId : oc.parentIdsOn(child)) {
                    Map<Id, String> byPrincipal = levelByParent.get(parentId);
                    if (byPrincipal == null) continue;
                    for (Id principalId : byPrincipal.keySet()) {
                        addShare(shares, buildShare(
                            oc, (Id) child.get('Id'), principalId, byPrincipal.get(principalId)));
                    }
                }
            }
        }
        return shares;
    }

    /**
     * @description Updates AccessLevel on shares that already exist for the same parent, user, and
     * row cause.
     * @author Melissa Rainboldt
     * @param incoming Desired share rows. Existing rows keep the highest access level.
     * @return void
     */
    private static void updateExistingShares(List<SObject> incoming) {
        if (incoming == null || incoming.isEmpty()) return;
        Map<String, List<SObject>> byType = new Map<String, List<SObject>>();
        for (SObject share : incoming) {
            String api = share.getSObjectType().getDescribe().getName();
            if (!byType.containsKey(api)) {
                byType.put(api, new List<SObject>());
            }
            byType.get(api).add(share);
        }
        List<SObject> toUpdate = new List<SObject>();
        for (String api : byType.keySet()) {
            List<SObject> groupShares = byType.get(api);
            Set<Id> parentIds = new Set<Id>();
            Set<Id> userIds = new Set<Id>();
            Set<String> causes = new Set<String>();
            Map<String, SObject> desiredByKey = new Map<String, SObject>();
            for (SObject share : groupShares) {
                Id parentId = (Id) share.get('ParentId');
                Id userId = (Id) share.get('UserOrGroupId');
                String cause = (String) share.get('RowCause');
                parentIds.add(parentId);
                userIds.add(userId);
                causes.add(cause);
                desiredByKey.put(shareKey(parentId, userId, cause), share);
            }
            for (SObject existing : Database.query(
                    'SELECT Id, ParentId, UserOrGroupId, RowCause, AccessLevel FROM ' + api
                    + ' WHERE ParentId IN :parentIds'
                    + ' AND UserOrGroupId IN :userIds'
                    + ' AND RowCause IN :causes')) {
                SObject desired = desiredByKey.get(shareKey(
                    (Id) existing.get('ParentId'),
                    (Id) existing.get('UserOrGroupId'),
                    (String) existing.get('RowCause')));
                if (desired == null){
                    System.debug(LoggingLevel.INFO, 'Desired share not found for existing share: ' + existing
                        + ', ParentId=' + existing.get('ParentId')
                        + ', UserOrGroupId=' + existing.get('UserOrGroupId')
                        + ', RowCause=' + existing.get('RowCause')
                        + ', AccessLevel=' + existing.get('AccessLevel'));
                    continue;
                }
                String want = (String) desired.get('AccessLevel');
                if (want == (String) existing.get('AccessLevel'))
                {
                    System.debug(LoggingLevel.INFO, 'Existing share already has desired access level. ShareId=' + existing
                        + ', ParentId=' + existing.get('ParentId')
                        + ', UserOrGroupId=' + existing.get('UserOrGroupId')
                        + ', RowCause=' + existing.get('RowCause')
                        + ', AccessLevel=' + existing.get('AccessLevel'));
                    continue;
                }
                existing.put('AccessLevel', want);
                toUpdate.add(existing);
            }
        }
        if (!toUpdate.isEmpty()) {
            List<Database.SaveResult> saveResults = Database.update(toUpdate, false);
            List<Error_Log__c> errorLogs = new List<Error_Log__c>();
            List<String> fatal = new List<String>();
            for (Integer i = 0; i < saveResults.size(); i++) {
                if (saveResults[i].isSuccess()) continue;
                errorLogs.add(ErrorUtil.logError(saveResults[i], false));
                for (Database.Error err : saveResults[i].getErrors()) {
                    fatal.add(shareDmlError(toUpdate[i], err));
                }
            }
            persistErrorLogs(errorLogs);
            throwIfShareDmlFailed('update', fatal);
        }
    }

    /**
     * @description Deletes engine-owned share rows. Partial-success DML; non-success rows
     * are logged then thrown so Sharing Queue workers markFailed.
     * @author Melissa Rainboldt
     * @param toDelete Engine-owned share rows to delete.
     * @return void
     */
    public static void deleteShares(List<SObject> toDelete) {
        if (toDelete == null || toDelete.isEmpty())
        {
            System.debug(LoggingLevel.INFO, 'deleteShares called with empty toDelete list');
            return;
        }
        List<Database.DeleteResult> deleteResults = Database.delete(toDelete, false);
        List<Error_Log__c> errorLogs = new List<Error_Log__c>();
        List<String> fatal = new List<String>();
        for (Integer i = 0; i < deleteResults.size(); i++) {
            if (deleteResults[i].isSuccess()) continue;
            errorLogs.add(ErrorUtil.logError(deleteResults[i], false));
            for (Database.Error err : deleteResults[i].getErrors()) {
                fatal.add(shareDmlError(toDelete[i], err));
            }
        }
        persistErrorLogs(errorLogs);
        throwIfShareDmlFailed('delete', fatal);
    }

    @TestVisible
    static final Integer SHARE_DML_ERROR_PREVIEW = 5;

    /**
     * @description Inserts the error log rows that share DML produced.
     * @author Melissa Rainboldt
     * @param errorLogs Error log rows to insert.
     * @return void
     */
    private static void persistErrorLogs(List<Error_Log__c> errorLogs) {
        if (errorLogs == null || errorLogs.isEmpty()) return;
        List<Error_Log__c> toInsert = new List<Error_Log__c>();
        for (Error_Log__c log : errorLogs) {
            if (log != null) toInsert.add(log);
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
    }

    /**
     * @description Formats one share DML error with the share's Id or parent and user.
     * @author Melissa Rainboldt
     * @param share Share sObject the operation applies to.
     * @param err Database error from the share DML.
     * @return A single-line DML error including the share identity.
     */
    private static String shareDmlError(SObject share, Database.Error err) {
        String whereClause = '';
        if (share != null) {
            if (share.Id != null) {
                whereClause = ' Id=' + share.Id;
            } else {
                try {
                    whereClause = ' ParentId=' + share.get('ParentId')
                        + ' UserOrGroupId=' + share.get('UserOrGroupId');
                } catch (Exception e) {
                    whereClause = '';
                }
            }
        }
        return String.valueOf(err.getStatusCode()) + whereClause + ': ' + err.getMessage();
    }

    /**
     * @description Throws SharingException when the message list is not empty.
     * @author Melissa Rainboldt
     * @param operation DML verb included in the exception, such as insert, update, or delete.
     * @param messages Fatal DML messages. Empty does not throw.
     * @return void
     */
    @TestVisible
    static void throwIfShareDmlFailed(String operation, List<String> messages) {
        if (messages == null || messages.isEmpty()) return;
        List<String> preview = new List<String>();
        Integer shown = Math.min(messages.size(), SHARE_DML_ERROR_PREVIEW);
        for (Integer i = 0; i < shown; i++) {
            preview.add(messages[i]);
        }
        String more = messages.size() > shown
            ? ' (+' + (messages.size() - shown) + ' more)'
            : '';
        throw new SharingConfigService.SharingException(
            'Share ' + operation + ' failed for ' + messages.size() + ' row(s)'
                + more + ': ' + String.join(preview, '; '));
    }

    /**
     * @description Returns the parent, user, and row-cause key for a share row.
     * @author Melissa Rainboldt
     * @param share Share sObject the operation applies to.
     * @return The parent, user, and row-cause key, or null when the share is null.
     */
    public static String shareRowKey(SObject share) {
        if (share == null) return null;
        return shareKey(
            (Id) share.get('ParentId'),
            (Id) share.get('UserOrGroupId'),
            (String) share.get('RowCause'));
    }

    /**
     * @description Returns the parent, user, and row-cause key for a share row.
     * @author Melissa Rainboldt
     * @param share Share sObject the operation applies to.
     * @return The parent, user, and row-cause key, or null when parent or user is missing.
     */
    private static String shareKey(SObject share) {
        return shareRowKey(share);
    }

    /**
     * @description Returns the parent, user, and row-cause key for a share row.
     * @author Melissa Rainboldt
     * @param parentId Parent record Id.
     * @param userOrGroupId User or group Id on the share.
     * @param rowCause Apex sharing reason stored on the share.
     * @return The parent, user, and row-cause key, or null when parent or user is missing.
     */
    private static String shareKey(Id parentId, Id userOrGroupId, String rowCause) {
        if (parentId == null || userOrGroupId == null)
        {
            System.debug(LoggingLevel.INFO, 'shareKey skipped: missing required parameters. parentId=' + parentId
                + ', userOrGroupId=' + userOrGroupId
                + ', rowCause=' + rowCause);
            return null;
        }
        return String.valueOf(parentId) + '|' + String.valueOf(userOrGroupId)
            + '|' + (rowCause == null ? '' : rowCause);
    }

    /**
     * @description Appends the share when it is not null.
     * @author Melissa Rainboldt
     * @param shares Share sObjects to insert, update, delete, or inspect.
     * @param share Share sObject the operation applies to.
     * @return void
     */
    private static void addShare(List<SObject> shares, SObject share) {
        if (share != null) shares.add(share);
    }

    /**
     * @description Builds one share sObject, or returns null when org-wide defaults already grant
     * that access.
     * @author Melissa Rainboldt
     * @param oc Sharing object configuration slice.
     * @param recordId Id stored as ParentId on the share.
     * @param userId User or group Id for the share.
     * @param accessLevel Share or team-member access level.
     * @return The share sObject, or null when it should be skipped.
     */
    private static SObject buildShare(SharingConfigService.ObjectConfig oc
                                    , Id recordId
                                    , Id userId
                                    , String accessLevel) {
        if (oc == null || SharingConfigService.owdAlreadyGrants(oc.childObjectApiName, accessLevel)) {
            System.debug(LoggingLevel.INFO, 'buildShare skipped: OWD already grants '
                + accessLevel + ' on ' + (oc == null ? null : oc.childObjectApiName));
            return null;
        }
        SObject share = (SObject) Type.forName(oc.shareObjectApiName).newInstance();
        share.put('ParentId', recordId);
        share.put('UserOrGroupId', userId);
        share.put('AccessLevel', accessLevel);
        share.put('RowCause', oc.rowCause);
        return share;
    }

    /**
     * @description Returns child Ids for the parents that belong to this slice.
     * @author Melissa Rainboldt
     * @param oc Sharing object configuration slice.
     * @param parentIds Parent record Ids whose sharing is in scope.
     * @return Child Ids on this slice for the parents.
     */
    private static Set<Id> queryChildIds(SharingConfigService.ObjectConfig oc, Set<Id> parentIds) {
        Set<Id> ids = new Set<Id>();
        String q = 'SELECT Id FROM ' + oc.childObjectApiName
            + ' WHERE ' + oc.whereParentIn('parentIds')
            + oc.andFilterClause();
        for (SObject r : Database.query(q)) {
            ids.add((Id) r.get('Id'));
        }
        return ids;
    }
}
