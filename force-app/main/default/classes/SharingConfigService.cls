/**
 * @description Loads team-member, object, and role-access configuration for one application and
 * resolves the Salesforce share access level.
 * @author Melissa Rainboldt
 */
public without sharing class SharingConfigService {

    // Per-application cache
    private static final Map<String, String> normalizedShareLevels = new Map<String, String>{
        'read' => 'Read'
        , 'read only' => 'Read'
        , 'create/edit' => 'Edit'
        , 'edit' => 'Edit'
        , 'all' => 'All'
    };

    private static Map<String, SharingConfigService> instances =
        new Map<String, SharingConfigService>();

    public String application;

    /**
     * @description Returns the cached configuration for the application. Blank application throws
     * SharingException.
     * @author Melissa Rainboldt
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The cached configuration for the application.
     */
    public static SharingConfigService getInstance(String application) {
        String key = normalizeApplication(application);
        if (String.isBlank(key)) {
            throw new SharingException(
                'Application is required to load sharing configuration.');
        }
        SharingConfigService cached = instances.get(key);
        if (cached == null) {
            cached = new SharingConfigService(application);
            instances.put(key, cached);
        }
        return cached;
    }

    /** InternalSharingModel by object API name (lowercase). Tests may seed this. */
    @TestVisible
    static Map<String, String> owdModelOverride = new Map<String, String>();
    private static Map<String, String> owdModelByObject = new Map<String, String>();

    /**
     * @description Clears the cache — call in tests after inserting config records.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestVisible
    private static void resetCache() {
        instances = new Map<String, SharingConfigService>();
        owdModelByObject = new Map<String, String>();
        owdModelOverride = new Map<String, String>();
    }

    /**
     * @description Trims and lowercases an application name. Blank becomes null.
     * @author Melissa Rainboldt
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The trimmed lowercase application, or null when blank.
     */
    @TestVisible
    static String normalizeApplication(String application) {
        return String.isBlank(application) ? null : application.trim().toLowerCase();
    }

    //Inner DTOs

    /**
     * @description Field mapping for the team member object of one application.
     * @author Melissa Rainboldt
     */
    public class TeamMemberConfig {
        public String objectApiName;
        public String parentLookupField;
        public String userField;
        public String groupField;
        public String roleField;
        public String accessLevelField;
        public String activeField; // nullable — if null, all records treated as active
        public Boolean useTeamMemberAccessLevel;
    }

    /**
     * @description One Sharing Object Config slice: child object, parent field, row cause, share
     * object, and optional filter.
     * @author Melissa Rainboldt
     */
    public class ObjectConfig {
        public Id     configId;
        public String childObjectApiName;
        public String parentLookupField;
        public List<String> parentLookupFields;
        public String rowCause;
        public String shareObjectApiName; // derived
        public String filterClause;

        /**
         * @description Returns whether this slice has a filter clause.
         * @author Melissa Rainboldt
         * @return True when filterClause is not blank.
         */
        public Boolean hasFilter() {
            return String.isNotBlank(filterClause);
        }

        /**
         * @description Reads parent Ids from the configured lookup, formula, or relationship path.
         * @author Melissa Rainboldt
         * @param rec Current sObject.
         * @return Parent Ids found on the record. Empty when the record or field list is missing.
         */
        public Set<Id> parentIdsOn(SObject rec) {
            Set<Id> ids = new Set<Id>();
            if (rec == null || parentLookupFields == null)
            {
                System.debug(LoggingLevel.INFO, 'parentIdsOn skipped: rec is null or parentLookupFields is null');
                return ids;
            }
            for (String field : parentLookupFields) {
                Id value = SharingConfigService.idOnPath(rec, field);
                if (value != null) ids.add(value);
            }
            return ids;
        }

        /**
         * @description Builds the SOQL select list needed to read this slice's parent fields.
         * @author Melissa Rainboldt
         * @return A comma-separated SOQL field list. Id when no parent field is configured.
         */
        public String selectParentFields() {
            Set<String> fields = new Set<String>();
            if (parentLookupFields == null) return 'Id';
            for (String field : parentLookupFields) {
                if (String.isBlank(field)) continue;
                fields.add(field);
                String expr = SharingConfigService.resolveSoqlParentExpression(
                    childObjectApiName, field);
                if (String.isNotBlank(expr)) fields.add(expr);
            }
            return fields.isEmpty() ? 'Id' : String.join(new List<String>(fields), ', ');
        }

        /**
         * @description Builds a SOQL predicate that binds one parent Id.
         * @author Melissa Rainboldt
         * @param bindName SOQL bind variable name, without a leading colon.
         * @return A SOQL predicate comparing the parent field to the bind.
         */
        public String whereParentEquals(String bindName) {
            List<String> parts = new List<String>();
            for (String field : parentLookupFields) {
                parts.add(
                    SharingConfigService.resolveSoqlParentExpression(childObjectApiName, field)
                    + ' = :' + bindName);
            }
            return parts.size() == 1 ? parts[0] : '(' + String.join(parts, ' OR ') + ')';
        }

        /**
         * @description Builds a SOQL predicate that binds a set of parent Ids.
         * @author Melissa Rainboldt
         * @param bindName SOQL bind variable name, without a leading colon.
         * @return A SOQL predicate comparing the parent field to the bind set.
         */
        public String whereParentIn(String bindName) {
            List<String> parts = new List<String>();
            for (String field : parentLookupFields) {
                parts.add(
                    SharingConfigService.resolveSoqlParentExpression(childObjectApiName, field)
                    + ' IN :' + bindName);
            }
            return parts.size() == 1 ? parts[0] : '(' + String.join(parts, ' OR ') + ')';
        }

        /**
         * @description Returns the filter clause prefixed with AND, or an empty string when there
         * is no filter.
         * @author Melissa Rainboldt
         * @return AND plus the filter, or an empty string when the slice is unfiltered.
         */
        public String andFilterClause() {
            return hasFilter() ? ' AND (' + filterClause + ')' : '';
        }

        /**
         * @description Which of the candidate Ids fall in this slice. Unfiltered configs return
         * all.
         * @author Melissa Rainboldt
         * @param candidateIds Record Ids tested against this slice's filter.
         * @return The candidate Ids that belong on this slice.
         */
        public Set<Id> matchingIds(Set<Id> candidateIds) {
            Set<Id> matched = new Set<Id>();
            if (candidateIds == null || candidateIds.isEmpty())
            {
                System.debug(LoggingLevel.INFO, 'matchingIds skipped: candidateIds is null or empty');
                return matched;
            }
            if (!hasFilter()) {
                matched.addAll(candidateIds);
                return matched;
            }
            Set<Id> bindIds = candidateIds;
            String q = 'SELECT Id FROM ' + childObjectApiName
                + ' WHERE Id IN :bindIds' + andFilterClause();
            System.debug('Query: ' + q + ' with bindIds=' + bindIds);
            for (SObject rec : Database.query(q)) {
                matched.add((Id) rec.get('Id'));
            }
            return matched;
        }
    }

    @TestVisible
    static final String INFER_FROM_TEAM_MEMBER = '*tm*';

    //Public state

    /** key: role + '|' + accessLevel + '|' + Sharing_Object_Config Id → share access or INFER_FROM_TEAM_MEMBER */
    public Map<String, String> permissionMap { get; private set; }
    public TeamMemberConfig teamMemberConfig { get; private set; }
    public List<ObjectConfig> objectConfigs { get; private set; }
    /** Default (unfiltered, else first) slice per child API name. */
    public Map<String, ObjectConfig> objectConfigByApiName { get; private set; }
    public Map<Id, ObjectConfig> objectConfigById { get; private set; }
    /** All slices for a child API name. */
    public Map<String, List<ObjectConfig>> objectConfigsByApiName { get; private set; }

    //Constructor

    /**
     * @description Loads team-member, object, and permission configuration for the application.
     * @author Melissa Rainboldt
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return A new SharingConfigService instance.
     */
    private SharingConfigService(String application) {
        this.application = application;
        loadTeamMemberConfig();
        loadObjectConfigs();
        loadPermissions();
    }

    //Loaders

    /**
     * @description Loads the team-member object and field mapping for this application.
     * @author Melissa Rainboldt
     * @return void
     */
    private void loadTeamMemberConfig() {
        List<Team_Member_Config__c> records = [SELECT Team_Member_Object_Api_Name__c
                                                    , Parent_Lookup_Field_Api_Name__c
                                                    , User_Field_Api_Name__c
                                                    , Group_Field_Api_Name__c
                                                    , Role_Field_Api_Name__c
                                                    , Access_Level_Field_Api_Name__c
                                                    , Active_Field_Api_Name__c
                                                    , Use_Team_Member_Access_Level__c
                                                FROM   Team_Member_Config__c
                                                WHERE  Is_Active__c = true
                                                AND    Application__c = :application
                                                ORDER BY LastModifiedDate DESC
                                                LIMIT  1
                                                ];
        if (records.isEmpty()) {
            throw new SharingException(
                'No active Team_Member_Config__c for Application ' + application + '.');
        }
        Team_Member_Config__c r = records[0];
        teamMemberConfig = new TeamMemberConfig();
        teamMemberConfig.objectApiName     = blankToNull(r.Team_Member_Object_Api_Name__c);
        teamMemberConfig.parentLookupField = blankToNull(r.Parent_Lookup_Field_Api_Name__c);
        teamMemberConfig.userField         = blankToNull(r.User_Field_Api_Name__c);
        teamMemberConfig.groupField        = blankToNull(r.Group_Field_Api_Name__c);
        teamMemberConfig.roleField         = blankToNull(r.Role_Field_Api_Name__c);
        teamMemberConfig.accessLevelField  = blankToNull(r.Access_Level_Field_Api_Name__c);
        teamMemberConfig.activeField       = blankToNull(r.Active_Field_Api_Name__c);
        teamMemberConfig.useTeamMemberAccessLevel = r.Use_Team_Member_Access_Level__c == true;
    }

    /**
     * @description Loads Sharing Object Config slices for this application.
     * @author Melissa Rainboldt
     * @return void
     */
    private void loadObjectConfigs() {
        objectConfigs           = new List<ObjectConfig>();
        objectConfigByApiName   = new Map<String, ObjectConfig>();
        objectConfigById        = new Map<Id, ObjectConfig>();
        objectConfigsByApiName  = new Map<String, List<ObjectConfig>>();

        for (Sharing_Object_Config__c r : [
            SELECT Id
                   , Child_Object_Api_Name__c
                   , Parent_Lookup_Field_Api_Name__c
                   , Row_Cause_Api_Name__c
                   , Filter_Clause__c
            FROM   Sharing_Object_Config__c
            WHERE  Is_Active__c = true
            AND    Application__c = :application
        ]) {
            ObjectConfig oc       = new ObjectConfig();
            oc.configId           = r.Id;
            oc.childObjectApiName = r.Child_Object_Api_Name__c;
            oc.parentLookupFields = parseFieldList(r.Parent_Lookup_Field_Api_Name__c);
            if (oc.parentLookupFields.isEmpty()) continue;
            oc.parentLookupField  = oc.parentLookupFields[0];
            oc.rowCause           = r.Row_Cause_Api_Name__c;
            oc.shareObjectApiName = deriveShareObjectName(r.Child_Object_Api_Name__c);
            oc.filterClause       = sanitizeFilterClause(r.Filter_Clause__c);
            objectConfigs.add(oc);
            objectConfigById.put(oc.configId, oc);
            String key = oc.childObjectApiName.toLowerCase();
            if (!objectConfigsByApiName.containsKey(key)) {
                objectConfigsByApiName.put(key, new List<ObjectConfig>());
            }
            objectConfigsByApiName.get(key).add(oc);
            if (!objectConfigByApiName.containsKey(key) || !oc.hasFilter()) {
                objectConfigByApiName.put(key, oc);
            }
        }
    }

    /**
     * @description Loads role-access permissions into the share-level map.
     * @author Melissa Rainboldt
     * @return void
     */
    private void loadPermissions() {
        permissionMap = new Map<String, String>();

        for (Role_Access_Permission__c r : [SELECT Role_Value__c
                                                    , Access_Level_Value__c
                                                    , Sharing_Object_Config__c
                                                    , Share_Access_Level__c
                                            FROM   Role_Access_Permission__c
                                            WHERE  Is_Active__c = true
                                            AND    Application__c = :application
                                            AND    Sharing_Object_Config__r.Is_Active__c = true
                                            AND    Sharing_Object_Config__r.Application__c = :application
                                        ])
        {
            if (r.Sharing_Object_Config__c == null)
            {
                System.debug(LoggingLevel.INFO, 'Skipping Role_Access_Permission__c ' + r.Id
                    + ' because Sharing_Object_Config__c is null');
                continue;
            }
            String mapped = blankToNull(r.Share_Access_Level__c);
            if (mapped == null) {
                System.debug(LoggingLevel.DEBUG, 'Role_Access_Permission__c ' + r.Id
                    + ' has blank Share_Access_Level__c; will infer from Team Member access level');
                mapped = INFER_FROM_TEAM_MEMBER;
            }
            permissionMap.put(
                buildPermKey(r.Role_Value__c, r.Access_Level_Value__c, r.Sharing_Object_Config__c),
                mapped);
        }
    }

    //Helpers

    /**
     * @description Resolves Salesforce share AccessLevel for a Team Member × slice.
     * When Use Team Member Access Level is checked, RAP is skipped for every
     * slice (filtered or not) and the Team Member access field is used.
     * Otherwise RAP on that Sharing_Object_Config gates whether a share is
     * created. Blank Share_Access_Level__c copies Read/Edit/All from the TM.
     * @author Melissa Rainboldt
     * @param role Team member role.
     * @param accessLevel Team member access level before role-access mapping.
     * @param childObjectApiName Child object whose slice is used for the role-access lookup.
     * @return The Salesforce AccessLevel to write, or null when no share should be created.
     */
    public String getShareAccessLevel(String role, String accessLevel, String childObjectApiName) {
        if (String.isBlank(childObjectApiName))
        {
            System.debug(LoggingLevel.INFO, 'getShareAccessLevel skipped: childObjectApiName is blank');
            return null;
        }
        return getShareAccessLevel(
            role, accessLevel, objectConfigByApiName.get(childObjectApiName.toLowerCase()));
    }

    /**
     * @description Resolves the Salesforce share access level for a team member and slice. Returns
     * null when no share should be created.
     * @author Melissa Rainboldt
     * @param role Team member role.
     * @param accessLevel Team member access level before role-access mapping.
     * @param oc Object slice whose role-access rows are consulted.
     * @return The Salesforce AccessLevel to write, or null when no share should be created.
     */
    public String getShareAccessLevel(String role, String accessLevel, ObjectConfig oc) {
        if (oc == null)
        {
            System.debug(LoggingLevel.INFO, 'getShareAccessLevel skipped: no ObjectConfig for role=' + role
                + ', accessLevel=' + accessLevel);
            return null;
        }
        if (teamMemberConfig != null && teamMemberConfig.useTeamMemberAccessLevel) {
            return normalizeShareLevel(accessLevel);
        }
        String mapped = permissionMap.get(buildPermKey(role, accessLevel, oc.configId));
        if (mapped == null) {
            mapped = permissionMap.get(
                buildPermKey(role, normalizeShareLevel(accessLevel), oc.configId));
        }
        if (mapped == null) {
            mapped = permissionMap.get(buildPermKey(role, null, oc.configId));
        }
        if (mapped == null)
        {
            System.debug(System.LoggingLevel.INFO, 'getShareAccessLevel skipped: no permission mapping for role=' + role
                + ', accessLevel=' + accessLevel
                + ', configId=' + oc.configId
                + ', childObjectApiName=' + oc.childObjectApiName);
            return null;
        }
        if (mapped == INFER_FROM_TEAM_MEMBER) {
            return normalizeShareLevel(accessLevel);
        }
        return mapped;
    }

    /**
     * @description Returns every slice whose child object API name matches.
     * @author Melissa Rainboldt
     * @param childObjectApiName API name of the related child object.
     * @return The slices for that child object. Empty when none are configured.
     */
    public List<ObjectConfig> configsForObject(String childObjectApiName) {
        if (String.isBlank(childObjectApiName)) return new List<ObjectConfig>();
        List<ObjectConfig> slices = objectConfigsByApiName.get(childObjectApiName.toLowerCase());
        return slices == null ? new List<ObjectConfig>() : slices;
    }

    /**
     * @description Slices to iterate in Batch. If objectApiNames is blank, every config.
     * Otherwise every slice whose child API name is listed (payload filter).
     * @author Melissa Rainboldt
     * @param objectApiNames Child object API names. Blank means every configured slice.
     * @return The slices to iterate. Every config when the name list is blank.
     */
    public List<ObjectConfig> slicesForObjects(List<String> objectApiNames) {
        if (objectApiNames == null || objectApiNames.isEmpty()) {
            System.debug(LoggingLevel.INFO, 'slicesForObjects called with empty objectApiNames');
            return objectConfigs;
        }
        Set<String> wanted = new Set<String>();
        for (String name : objectApiNames) {
            if (String.isNotBlank(name)) wanted.add(name.toLowerCase());
        }
        List<ObjectConfig> slices = new List<ObjectConfig>();
        for (ObjectConfig oc : objectConfigs) {
            if (wanted.contains(oc.childObjectApiName.toLowerCase())) {
                slices.add(oc);
            }
        }
        return slices;
    }

    

    /**
     * @description True when InternalSharingModel already grants this Salesforce share
     * AccessLevel. Private / ControlledByParent / unknown never skip.
     * @author Melissa Rainboldt
     * @param objectApiName Object whose org-wide default is checked.
     * @param accessLevel Share access level the caller wants to grant.
     * @return True when the org-wide default already grants this access level.
     */
    public static Boolean owdAlreadyGrants(String objectApiName, String accessLevel) {
        Integer granted = owdAccessRank(internalSharingModel(objectApiName));
        Integer needed = shareAccessRank(accessLevel);
        if (granted <= 0 || needed <= 0) return false;
        return granted >= needed;
    }

    /**
     * @description Ranks an org-wide default. Read is 1, read/write and full access are 2, and
     * private is 0.
     * @author Melissa Rainboldt
     * @param internalSharingModel EntityDefinition.InternalSharingModel value.
     * @return 1 for Read, 2 for read/write or full access, and 0 when sharing is not granted.
     */
    @TestVisible
    static Integer owdAccessRank(String internalSharingModel) {
        if (String.isBlank(internalSharingModel)) return 0;
        String model = internalSharingModel.trim().toLowerCase();
        if (model == 'read') return 1;
        if (model == 'readwrite' || model == 'readwritetransfer' || model == 'fullaccess') {
            return 2;
        }
        return 0;
    }

    /**
     * @description Ranks a share access level. Read is 1, Edit and All are 2, and unknown is 0.
     * @author Melissa Rainboldt
     * @param accessLevel Share or team-member access level.
     * @return 1 for Read, 2 for Edit or All, and 0 when the level is unknown.
     */
    @TestVisible
    static Integer shareAccessRank(String accessLevel) {
        String normalized = normalizeShareLevel(accessLevel);
        if (normalized == 'Read') return 1;
        if (normalized == 'Edit' || normalized == 'All') return 2;
        return 0;
    }

    /**
     * @description Returns the cached InternalSharingModel for the object.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @return The InternalSharingModel, or null when it cannot be read.
     */
    private static String internalSharingModel(String objectApiName) {
        if (String.isBlank(objectApiName)) return null;
        String key = objectApiName.trim().toLowerCase();
        if (owdModelOverride.containsKey(key)) return owdModelOverride.get(key);
        if (owdModelByObject.containsKey(key)) return owdModelByObject.get(key);
        String model;
        try {
            List<EntityDefinition> rows = [
                SELECT InternalSharingModel
                FROM EntityDefinition
                WHERE QualifiedApiName = :objectApiName
                LIMIT 1
            ];
            model = rows.isEmpty() ? null : String.valueOf(rows[0].InternalSharingModel);
        } catch (Exception e) {
            System.debug(LoggingLevel.INFO, 'OWD lookup skipped for ' + objectApiName
                + ': ' + e.getMessage());
            model = null;
        }
        owdModelByObject.put(key, model);
        return model;
    }

    /**
     * @description Maps a team-member access value to Read, Edit, or All.
     * @author Melissa Rainboldt
     * @param accessLevel Raw access level from a team member, payload, or permission row.
     * @return Read, Edit, or All, or null when the value is blank or unknown.
     */
    public static String normalizeShareLevel(String accessLevel) {
        if (String.isBlank(accessLevel))
        {
            System.debug(LoggingLevel.INFO, 'normalizeShareLevel skipped: accessLevel is blank');
            return null;
        }
        String normalized = accessLevel.trim().toLowerCase();
        return normalizedShareLevels.get(normalized);
    }

    /**
     * @description Builds the role, access, and config key used in the permission map.
     * @author Melissa Rainboldt
     * @param role Team member role.
     * @param accessLevel Share or team-member access level.
     * @param configId Sharing Object Config Id.
     * @return The lowercase role, access, and config key.
     */
    private String buildPermKey(String role, String accessLevel, Id configId) {
        String rolePart = role == null ? '' : role.trim();
        String accessPart = accessLevel == null ? '' : accessLevel.trim();
        String idPart = configId == null ? '' : String.valueOf(configId);
        return (rolePart + '|' + accessPart + '|' + idPart).toLowerCase();
    }

    /**
     * @description Admin-supplied SOQL condition only. No binds, no DML, no extra FROM/SELECT.
     * @author Melissa Rainboldt
     * @param raw Untrusted or unparsed text.
     * @return The condition with a leading WHERE and trailing semicolon removed.
     */
    @TestVisible
    static String sanitizeFilterClause(String raw) {
        if (String.isBlank(raw)) return null;
        String clause = raw.trim();
        if (clause.endsWith(';')) {
            clause = clause.substring(0, clause.length() - 1).trim();
        }
        if (clause.length() >= 5 && clause.substring(0, 5).toUpperCase() == 'WHERE') {
            clause = clause.substring(5).trim();
        }
        if (String.isBlank(clause)) return null;
        if (clause.contains(':') || clause.contains('--') || clause.contains('/*')) {
            throw new SharingException(
                'Sharing_Object_Config__c Filter Clause cannot contain binds or comments: ' + clause);
        }
        String padded = ' ' + clause.replaceAll('\\s+', ' ').toUpperCase() + ' ';
        for (String banned : new List<String>{
            ' INSERT ', ' UPDATE ', ' DELETE ', ' UNDELETE ', ' MERGE ', ' UPSERT ',
            ' SELECT ', ' FROM ', ';'
        }) {
            if (padded.contains(banned)) {
                throw new SharingException(
                    'Sharing_Object_Config__c Filter Clause must be a condition only: ' + clause);
            }
        }
        return clause;
    }

    /**
     * @description Derives the Apex share object name from the sObject API name.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @return The Apex share object API name.
     */
    public static String deriveShareObjectName(String objectApiName) {
        if (objectApiName.endsWith('__c')) {
            return objectApiName.removeEnd('__c') + '__Share';
        }
        return objectApiName + 'Share';
    }

    /**
     * @description Returns the trimmed text, or null when it is blank.
     * @author Melissa Rainboldt
     * @param value Text that becomes null when it is blank.
     * @return The trimmed text, or null when blank.
     */
    private static String blankToNull(String value) {
        if (String.isBlank(value)) return null;
        return value.trim();
    }

    /**
     * @description Splits a field list on commas, spaces, and semicolons.
     * @author Melissa Rainboldt
     * @param raw Untrusted or unparsed text.
     * @return Distinct field API names. Empty when the raw text is blank.
     */
    @TestVisible
    static List<String> parseFieldList(String raw) {
        List<String> fields = new List<String>();
        if (String.isBlank(raw)) return fields;
        for (String token : raw.split('[\\s,;]+')) {
            if (String.isBlank(token)) continue;
            String name = token.trim();
            if (!fields.contains(name)) fields.add(name);
        }
        return fields;
    }

    /**
     * @description Loads related records with configured parent fields (lookup, formula, or path).
     * Does not write those fields — formulas are read-only.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @param recordIds Record Ids to query.
     * @return The related records with parent fields populated.
     */
    public List<SObject> queryRelatedRecords(String objectApiName, Set<Id> recordIds) {
        if (String.isBlank(objectApiName) || recordIds == null || recordIds.isEmpty()) {
            return new List<SObject>();
        }
        Set<String> selectFields = new Set<String>{ 'Id' };
        for (ObjectConfig oc : configsForObject(objectApiName)) {
            for (String field : oc.selectParentFields().split(',')) {
                String name = field == null ? null : field.trim();
                if (String.isNotBlank(name)) selectFields.add(name);
            }
        }
        Set<Id> bindIds = recordIds;
        String q = 'SELECT ' + String.join(new List<String>(selectFields), ', ')
            + ' FROM ' + objectApiName
            + ' WHERE Id IN :bindIds';
        return Database.query(q);
    }

    /**
     * @description Trigger.new often lacks formula values and relationship parents. Re-query
     * when the configured parent field is not populated — never write formulas.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @param records Source records for this operation.
     * @return The original records, replaced by queried rows where the parent field was missing.
     */
    public List<SObject> hydrateRelatedRecords(String objectApiName, List<SObject> records) {
        if (String.isBlank(objectApiName) || records == null || records.isEmpty()) {
            return records;
        }
        List<ObjectConfig> slices = configsForObject(objectApiName);
        ObjectConfig oc = slices.isEmpty()
            ? objectConfigByApiName.get(objectApiName.toLowerCase())
            : slices[0];
        if (oc == null) return records;

        Boolean missingParent = false;
        Set<Id> recordIds = new Set<Id>();
        for (SObject rec : records) {
            Id recordId = rec == null ? null : (Id) rec.get('Id');
            if (recordId != null) recordIds.add(recordId);
            if (oc.parentIdsOn(rec).isEmpty()) missingParent = true;
        }
        if (!missingParent || recordIds.isEmpty()) return records;

        Map<Id, SObject> queried = new Map<Id, SObject>();
        for (SObject rec : queryRelatedRecords(objectApiName, recordIds)) {
            queried.put((Id) rec.get('Id'), rec);
        }
        List<SObject> hydrated = new List<SObject>();
        for (SObject rec : records) {
            Id recordId = rec == null ? null : (Id) rec.get('Id');
            SObject loaded = recordId == null ? null : queried.get(recordId);
            hydrated.add(loaded != null ? loaded : rec);
        }
        return hydrated;
    }

    /**
     * @description SOQL expression for filtering by this parent field. Lookups and filterable
     * formulas stay as-is. A non-filterable formula that is a simple field
     * reference (e.g. Child__r.Matter__c) is replaced by that path.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @param field Parent field or relationship path from the object config.
     * @return The SOQL expression to filter on this parent field.
     */
    public static String resolveSoqlParentExpression(String objectApiName, String field) {
        if (String.isBlank(field)) return field;
        String trimmed = field.trim();
        if (trimmed.contains('.')) return trimmed;
        Schema.DescribeFieldResult described = describeField(objectApiName, trimmed);
        if (described == null || described.isFilterable()) return trimmed;
        if (described.isCalculated()) {
            String path = simpleFormulaPath(described.getCalculatedFormula());
            if (String.isNotBlank(path)) return path;
            throw new SharingException(
                objectApiName + '.' + trimmed
                + ' is a formula that cannot be filtered. Set Parent Lookup to a lookup '
                + 'or relationship path (e.g. Document__r.Matter__c).');
        }
        throw new SharingException(
            objectApiName + '.' + trimmed
            + ' cannot be filtered in SOQL. Set Parent Lookup to a lookup, filterable formula, '
            + 'or relationship path.');
    }

    /**
     * @description Returns the relationship path inside a simple field-reference formula.
     * @author Melissa Rainboldt
     * @param formula Calculated formula text.
     * @return The relationship path, or null when the formula is not a simple field reference.
     */
    @TestVisible
    static String simpleFormulaPath(String formula) {
        if (String.isBlank(formula)) return null;
        String text = formula.trim();
        while (text.startsWith('(') && text.endsWith(')') && text.length() > 2) {
            text = text.substring(1, text.length() - 1).trim();
        }
        String wrapped = text.toLowerCase();
        if (wrapped.startsWith('casesafeid(') && wrapped.endsWith(')')) {
            text = text.substring('CASESAFEID('.length(), text.length() - 1).trim();
        }
        if (!Pattern.matches('(?i)^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*$', text)) {
            return null;
        }
        return text;
    }

    private static Map<String, Map<String, Schema.SObjectField>> fieldsByObject;

    /**
     * @description Describes a field, using a per-transaction describe cache.
     * @author Melissa Rainboldt
     * @param objectApiName API name of the sObject.
     * @param fieldApi API name of the field to read or compare.
     * @return The field describe, or null when the object or field is unknown.
     */
    static Schema.DescribeFieldResult describeField(String objectApiName, String fieldApi) {
        if (String.isBlank(objectApiName) || String.isBlank(fieldApi)) return null;
        if (fieldsByObject == null) {
            fieldsByObject = new Map<String, Map<String, Schema.SObjectField>>();
        }
        String objKey = objectApiName.toLowerCase();
        if (!fieldsByObject.containsKey(objKey)) {
            Schema.SObjectType token = Schema.getGlobalDescribe().get(objectApiName);
            fieldsByObject.put(
                objKey,
                token == null
                    ? new Map<String, Schema.SObjectField>()
                    : token.getDescribe().fields.getMap());
        }
        Schema.SObjectField fieldToken = fieldsByObject.get(objKey).get(fieldApi);
        return fieldToken == null ? null : fieldToken.getDescribe();
    }

    /**
     * @description Walks a lookup/formula field or relationship path (e.g. Account.ParentId).
     * @author Melissa Rainboldt
     * @param rec Current sObject.
     * @param path Field or relationship path, such as Account.ParentId.
     * @return The Id at the end of the path, or null when a step is missing.
     */
    public static Id idOnPath(SObject rec, String path) {
        if (rec == null || String.isBlank(path)) return null;
        SObject current = rec;
        List<String> parts = path.split('\\.');
        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i].trim();
            if (String.isBlank(part) || current == null) return null;
            if (i == parts.size() - 1) {
                return coerceId(current.get(part));
            }
            current = current.getSObject(part);
        }
        return null;
    }

    /**
     * @description Returns an Id when the value is already an Id or 15/18-character text.
     * @author Melissa Rainboldt
     * @param value A value that may already be an Id or a 15- or 18-character string.
     * @return The Id, or null when the value is not an Id.
     */
    @TestVisible
    static Id coerceId(Object value) {
        if (value == null) return null;
        if (value instanceof Id) return (Id) value;
        String text = String.valueOf(value);
        if (String.isBlank(text) || text.length() < 15 || text.length() > 18) return null;
        try {
            return (Id) text;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * @description Thrown when sharing configuration or a job handler cannot be resolved.
     * @author Melissa Rainboldt
     */
    public class SharingException extends Exception {}
}
