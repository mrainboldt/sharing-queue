/**
 * @description Tests sharing-config access resolution, parent paths, filter clauses, and
 * org-wide-default skips.
 * @author Melissa Rainboldt
 */
@IsTest
private class SharingConfigServiceTest {

    /**
     * @description Inserts records shared by the tests in this class.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestSetup
    static void makeData() {
        insert new Team_Member_Config__c(
            Name = 'Test TM Config',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Role_Field_Api_Name__c = 'Title',
            Access_Level_Field_Api_Name__c = 'LocaleSidKey',
            Use_Team_Member_Access_Level__c = false,
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        Sharing_Object_Config__c child = new Sharing_Object_Config__c(
            Name = 'Account children',
            Child_Object_Api_Name__c = 'Account',
            Parent_Lookup_Field_Api_Name__c = 'ParentId',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        insert child;
        insert new List<Role_Access_Permission__c>{
            new Role_Access_Permission__c(
                Name = 'Attorney infers TM access',
                Sharing_Object_Config__c = child.Id,
                Role_Value__c = 'Attorney',
                Access_Level_Value__c = null,
                Share_Access_Level__c = null,
                Is_Active__c = true,
                Application__c = JobCatalogService.APP_APPLICATION1
            ),
            new Role_Access_Permission__c(
                Name = 'Paralegal capped at Read',
                Sharing_Object_Config__c = child.Id,
                Role_Value__c = 'Paralegal',
                Access_Level_Value__c = null,
                Share_Access_Level__c = 'Read',
                Is_Active__c = true,
                Application__c = JobCatalogService.APP_APPLICATION1
            )
        };
    }

    /**
     * @description Verifies blank share access level copies team member access.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testBlankShareAccessLevelCopiesTeamMemberAccess() {
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);
        System.assertEquals('Edit', cfg.getShareAccessLevel('Attorney', 'Edit', 'Account'));
        System.assertEquals('Read', cfg.getShareAccessLevel('Attorney', 'read', 'Account'));
        System.assertEquals(null, cfg.getShareAccessLevel('Attorney', 'Full', 'Account'));
        System.assertEquals(null, cfg.getShareAccessLevel('Unknown', 'Edit', 'Account'));
    }

    /**
     * @description Verifies explicit share access level wins.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testExplicitShareAccessLevelWins() {
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);
        System.assertEquals('Read', cfg.getShareAccessLevel('Paralegal', 'Edit', 'Account'));
    }

    /**
     * @description Verifies RAP access level filter matches create edit alias.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRapAccessLevelFilterMatchesCreateEditAlias() {
        Sharing_Object_Config__c child = [
            SELECT Id FROM Sharing_Object_Config__c
            WHERE Child_Object_Api_Name__c = 'Account'
            AND Application__c = :JobCatalogService.APP_APPLICATION1
            LIMIT 1
        ];
        insert new Role_Access_Permission__c(
            Name = 'Partner Edit filter',
            Sharing_Object_Config__c = child.Id,
            Role_Value__c = 'Partner',
            Access_Level_Value__c = 'Edit',
            Share_Access_Level__c = 'Read',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);

        System.assertEquals(
            'Read',
            cfg.getShareAccessLevel('Partner', 'Create/Edit', 'Account'),
            'Create/Edit on the Team Member should match a RAP Access Level Value of Edit');
        System.assertEquals(
            'Read',
            cfg.getShareAccessLevel('Partner', 'Edit', 'Account'));
        System.assertEquals(
            null,
            cfg.getShareAccessLevel('Partner', 'Read', 'Account'),
            'A RAP Access Level Value of Edit should not match TM Read');
    }

    /**
     * @description Verifies RAP role and access trimmed.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRapRoleAndAccessTrimmed() {
        Sharing_Object_Config__c child = [
            SELECT Id FROM Sharing_Object_Config__c
            WHERE Child_Object_Api_Name__c = 'Account'
            AND Application__c = :JobCatalogService.APP_APPLICATION1
            LIMIT 1
        ];
        insert new Role_Access_Permission__c(
            Name = 'Whitespace role',
            Sharing_Object_Config__c = child.Id,
            Role_Value__c = ' Investigator ',
            Access_Level_Value__c = ' Create/Edit ',
            Share_Access_Level__c = 'Edit',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);
        System.assertEquals(
            'Edit',
            cfg.getShareAccessLevel('Investigator', 'Create/Edit', 'Account'));
    }

    /**
     * @description Verifies normalize share level.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testNormalizeShareLevel() {
        System.assertEquals('Read', SharingConfigService.normalizeShareLevel('read'));
        System.assertEquals('Edit', SharingConfigService.normalizeShareLevel(' Edit '));
        System.assertEquals('All', SharingConfigService.normalizeShareLevel('ALL'));
        System.assertEquals(null, SharingConfigService.normalizeShareLevel('Full'));
        System.assertEquals(null, SharingConfigService.normalizeShareLevel(null));
    }

    /**
     * @description Verifies sanitize filter clause.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testSanitizeFilterClause() {
        System.assertEquals(
            'Type = \'Prospect\'',
            SharingConfigService.sanitizeFilterClause('WHERE Type = \'Prospect\''));
        System.assertEquals(null, SharingConfigService.sanitizeFilterClause('  '));
        Boolean threw = false;
        try {
            SharingConfigService.sanitizeFilterClause('SELECT Id FROM Account');
        } catch (SharingConfigService.SharingException e) {
            threw = true;
        }
        System.assert(threw, 'SELECT/FROM should be rejected');
        threw = false;
        try {
            SharingConfigService.sanitizeFilterClause('Id = :parentId');
        } catch (SharingConfigService.SharingException e) {
            threw = true;
        }
        System.assert(threw, 'Binds should be rejected');
    }

    /**
     * @description Verifies filtered slice uses its own permissions.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testFilteredSliceUsesItsOwnPermissions() {
        Sharing_Object_Config__c restricted = new Sharing_Object_Config__c(
            Name = 'Account restricted',
            Child_Object_Api_Name__c = 'Account',
            Parent_Lookup_Field_Api_Name__c = 'ParentId',
            Row_Cause_Api_Name__c = 'Manual',
            Filter_Clause__c = 'Type = \'Prospect\'',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        insert restricted;
        insert new Role_Access_Permission__c(
            Name = 'Attorney on restricted',
            Sharing_Object_Config__c = restricted.Id,
            Role_Value__c = 'Attorney',
            Share_Access_Level__c = 'Edit',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);
        SharingConfigService.ObjectConfig slice;
        for (SharingConfigService.ObjectConfig oc : cfg.configsForObject('Account')) {
            if (oc.hasFilter()) slice = oc;
        }
        System.assertNotEquals(null, slice);
        System.assertEquals('Edit', cfg.getShareAccessLevel('Attorney', 'Edit', slice));
        System.assertEquals(null, cfg.getShareAccessLevel('Paralegal', 'Edit', slice));
        System.assertEquals('Read', cfg.getShareAccessLevel('Paralegal', 'Edit', 'Account'));
        System.assertEquals(2, cfg.configsForObject('Account').size());
    }

    /**
     * @description Verifies use team member access level applies to filtered slice.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testUseTeamMemberAccessLevelAppliesToFilteredSlice() {
        Team_Member_Config__c tmc = [
            SELECT Id FROM Team_Member_Config__c
            WHERE Application__c = :JobCatalogService.APP_APPLICATION1
            LIMIT 1
        ];
        tmc.Use_Team_Member_Access_Level__c = true;
        update tmc;
        insert new Sharing_Object_Config__c(
            Name = 'Account filtered uses TM access',
            Child_Object_Api_Name__c = 'Account',
            Parent_Lookup_Field_Api_Name__c = 'ParentId',
            Row_Cause_Api_Name__c = 'Manual',
            Filter_Clause__c = 'Type = \'Prospect\'',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);
        SharingConfigService.ObjectConfig slice;
        for (SharingConfigService.ObjectConfig oc : cfg.configsForObject('Account')) {
            if (oc.hasFilter()) slice = oc;
        }
        System.assertNotEquals(null, slice);
        System.assertEquals('Edit', cfg.getShareAccessLevel('UnknownRole', 'Edit', slice));
        System.assertEquals('Read', cfg.getShareAccessLevel('Paralegal', 'read', slice));
        System.assertEquals(null, cfg.getShareAccessLevel('Attorney', 'Full', slice));
    }

    /**
     * @description Verifies blank application throws.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testBlankApplicationThrows() {
        Boolean threw = false;
        try {
            SharingConfigService.getInstance(null);
        } catch (SharingConfigService.SharingException e) {
            threw = true;
            System.assert(e.getMessage().contains('Application is required'));
        }
        System.assert(threw);
    }

    /**
     * @description Verifies config is isolated by application.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testConfigIsIsolatedByApplication() {
        insert new Team_Member_Config__c(
            Name = 'GLS TM Config',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Role_Field_Api_Name__c = 'Title',
            Access_Level_Field_Api_Name__c = 'LocaleSidKey',
            Use_Team_Member_Access_Level__c = false,
            Is_Active__c = true,
            Application__c = 'GLS'
        );
        Sharing_Object_Config__c glsChild = new Sharing_Object_Config__c(
            Name = 'GLS Contact children',
            Child_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'AccountId',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = 'GLS'
        );
        insert glsChild;
        insert new Role_Access_Permission__c(
            Name = 'GLS Attorney',
            Sharing_Object_Config__c = glsChild.Id,
            Role_Value__c = 'Attorney',
            Share_Access_Level__c = 'Read',
            Is_Active__c = true,
            Application__c = 'GLS'
        );
        SharingConfigService.resetCache();

        SharingConfigService occ = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);
        SharingConfigService gls = SharingConfigService.getInstance('GLS');

        System.assertEquals(1, occ.objectConfigs.size());
        System.assertEquals('Account', occ.objectConfigs[0].childObjectApiName);
        System.assertEquals('Edit', occ.getShareAccessLevel('Attorney', 'Edit', 'Account'));
        System.assertEquals(0, occ.configsForObject('Contact').size());

        System.assertEquals(1, gls.objectConfigs.size());
        System.assertEquals('Contact', gls.objectConfigs[0].childObjectApiName);
        System.assertEquals('Read', gls.getShareAccessLevel('Attorney', 'Edit', 'Contact'));
        System.assertEquals(0, gls.configsForObject('Account').size());
    }

    /**
     * @description Verifies parent Ids on direct lookup.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testParentIdsOnDirectLookup() {
        Account parent = new Account(Name = 'Main');
        insert parent;
        Contact child = new Contact(LastName = 'Related', AccountId = parent.Id);
        insert child;
        Contact queried = [SELECT Id, AccountId FROM Contact WHERE Id = :child.Id];

        SharingConfigService.ObjectConfig oc = new SharingConfigService.ObjectConfig();
        oc.parentLookupFields = new List<String>{ 'AccountId' };
        System.assertEquals(new Set<Id>{ parent.Id }, oc.parentIdsOn(queried));
    }

    /**
     * @description Verifies parent Ids on relationship path.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testParentIdsOnRelationshipPath() {
        Account grandparent = new Account(Name = 'Grandparent');
        insert grandparent;
        Account parent = new Account(Name = 'Parent', ParentId = grandparent.Id);
        insert parent;
        Contact grandchild = new Contact(LastName = 'Grandchild', AccountId = parent.Id);
        insert grandchild;
        Contact queried = [
            SELECT Id, Account.ParentId
            FROM Contact
            WHERE Id = :grandchild.Id
        ];

        SharingConfigService.ObjectConfig oc = new SharingConfigService.ObjectConfig();
        oc.parentLookupFields = new List<String>{ 'Account.ParentId' };
        System.assertEquals(new Set<Id>{ grandparent.Id }, oc.parentIdsOn(queried));
        System.assertEquals(
            grandparent.Id,
            SharingConfigService.idOnPath(queried, 'Account.ParentId'));
        System.assertEquals(null, SharingConfigService.idOnPath(grandchild, 'Account.ParentId'));
    }

    /**
     * @description Verifies Id on path coerces text Id.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testIdOnPathCoercesTextId() {
        Account parent = new Account(Name = 'Main');
        insert parent;
        System.assertEquals(
            parent.Id,
            SharingConfigService.idOnPath(
                new Account(Id = parent.Id, Description = String.valueOf(parent.Id)),
                'Description'));
        System.assertEquals(null, SharingConfigService.idOnPath(parent, null));
        System.assertEquals(null, SharingConfigService.idOnPath(null, 'Id'));
    }

    /**
     * @description Verifies share related to all team members queries relationship path.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testShareRelatedToAllTeamMembersQueriesRelationshipPath() {
        insert new Sharing_Object_Config__c(
            Name = 'Contact via Account.ParentId',
            Child_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'Account.ParentId',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        Account grandparent = new Account(Name = 'Grandparent');
        insert grandparent;
        Account parent = new Account(Name = 'Parent', ParentId = grandparent.Id);
        insert parent;
        Contact grandchild = new Contact(LastName = 'Grandchild', AccountId = parent.Id);
        insert grandchild;
        SharingConfigService.resetCache();

        Sharing_Queue__c queue = new Sharing_Queue__c(
            Trigger_Event__c = JobCatalogService.EVENT_RELATED_RECORD_CREATED,
            Main_Record_Id__c = String.valueOf(grandparent.Id),
            Main_Object_Api_Name__c = 'Account',
            Source_Record_Id__c = String.valueOf(grandchild.Id),
            Source_Object_Api_Name__c = 'Contact',
            Application__c = JobCatalogService.APP_APPLICATION1,
            Status__c = SharingQueueService.STATUS_PENDING
        );

        Integer processed = new ShareRelatedToAllTeamMembers().process(queue);
        System.assertEquals(0, processed);
        List<SObject> loaded = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1)
            .queryRelatedRecords('Contact', new Set<Id>{ grandchild.Id });
        System.assertEquals(1, loaded.size());
        System.assertEquals(
            grandparent.Id,
            SharingConfigService.idOnPath(loaded[0], 'Account.ParentId'));
    }

    /**
     * @description Verifies enqueue hydrates relationship parent.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testEnqueueHydratesRelationshipParent() {
        insert new Sharing_Object_Config__c(
            Name = 'Contact via Account.ParentId enqueue',
            Child_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'Account.ParentId',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        Account grandparent = new Account(Name = 'Grandparent');
        insert grandparent;
        Account parent = new Account(Name = 'Parent', ParentId = grandparent.Id);
        insert parent;
        Contact grandchild = new Contact(LastName = 'Grandchild', AccountId = parent.Id);
        insert grandchild;
        SharingConfigService.resetCache();
        JobCatalogService.seedCatalogOCC();

        Contact triggerStyle = new Contact(Id = grandchild.Id, AccountId = parent.Id);
        Integer inserted = SharingQueueService.enqueueFromRelatedRecords(
            'Contact',
            new List<SObject>{ triggerStyle },
            JobCatalogService.APP_APPLICATION1);

        System.assertEquals(1, inserted);
        Sharing_Queue__c row = [
            SELECT Main_Record_Id__c, Source_Record_Id__c
            FROM Sharing_Queue__c
            WHERE Source_Record_Id__c = :String.valueOf(grandchild.Id)
            LIMIT 1
        ];
        System.assertEquals(String.valueOf(grandparent.Id), row.Main_Record_Id__c);
    }

    /**
     * @description Verifies share related to all team members reads formula like parent field.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testShareRelatedToAllTeamMembersReadsFormulaLikeParentField() {
        insert new Sharing_Object_Config__c(
            Name = 'Contact via Description formula stand-in',
            Child_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'Description',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        Account main = new Account(Name = 'Main');
        insert main;
        Contact grandchild = new Contact(
            LastName = 'Grandchild',
            Description = String.valueOf(main.Id)
        );
        insert grandchild;
        SharingConfigService.resetCache();

        Sharing_Queue__c queue = new Sharing_Queue__c(
            Trigger_Event__c = JobCatalogService.EVENT_RELATED_RECORD_CREATED,
            Main_Record_Id__c = String.valueOf(main.Id),
            Main_Object_Api_Name__c = 'Account',
            Source_Record_Id__c = String.valueOf(grandchild.Id),
            Source_Object_Api_Name__c = 'Contact',
            Application__c = JobCatalogService.APP_APPLICATION1,
            Status__c = SharingQueueService.STATUS_PENDING
        );

        Integer processed = new ShareRelatedToAllTeamMembers().process(queue);
        System.assertEquals(0, processed);
        List<SObject> loaded = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1)
            .queryRelatedRecords('Contact', new Set<Id>{ grandchild.Id });
        System.assertEquals(1, loaded.size());
        System.assertEquals(
            main.Id,
            SharingConfigService.idOnPath(loaded[0], 'Description'));
    }

    /**
     * @description Verifies enqueue hydrates formula like parent field.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testEnqueueHydratesFormulaLikeParentField() {
        insert new Sharing_Object_Config__c(
            Name = 'Contact via Description enqueue',
            Child_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'Description',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        Account main = new Account(Name = 'Main');
        insert main;
        Contact grandchild = new Contact(
            LastName = 'Grandchild',
            Description = String.valueOf(main.Id)
        );
        insert grandchild;
        SharingConfigService.resetCache();
        JobCatalogService.seedCatalogOCC();

        Contact triggerStyle = new Contact(Id = grandchild.Id);
        Integer inserted = SharingQueueService.enqueueFromRelatedRecords(
            'Contact',
            new List<SObject>{ triggerStyle },
            JobCatalogService.APP_APPLICATION1);

        System.assertEquals(1, inserted);
        Sharing_Queue__c row = [
            SELECT Main_Record_Id__c
            FROM Sharing_Queue__c
            WHERE Source_Record_Id__c = :String.valueOf(grandchild.Id)
            LIMIT 1
        ];
        System.assertEquals(String.valueOf(main.Id), row.Main_Record_Id__c);
    }

    /**
     * @description Verifies simple formula path unwraps field reference.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testSimpleFormulaPathUnwrapsFieldReference() {
        System.assertEquals(
            'Child__r.Matter__c',
            SharingConfigService.simpleFormulaPath('Child__r.Matter__c'));
        System.assertEquals(
            'Child__r.Matter__c',
            SharingConfigService.simpleFormulaPath(' (Child__r.Matter__c) '));
        System.assertEquals(
            'Child__r.Matter__c',
            SharingConfigService.simpleFormulaPath('CASESAFEID(Child__r.Matter__c)'));
        System.assertEquals(
            null,
            SharingConfigService.simpleFormulaPath('IF(true, Child__r.Matter__c, null)'));
        System.assertEquals(
            'AccountId',
            SharingConfigService.resolveSoqlParentExpression('Contact', 'AccountId'));
        System.assertEquals(
            'Account.ParentId',
            SharingConfigService.resolveSoqlParentExpression('Contact', 'Account.ParentId'));
    }

    /**
     * @description Verifies where parent uses relationship path.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testWhereParentUsesRelationshipPath() {
        SharingConfigService.ObjectConfig oc = new SharingConfigService.ObjectConfig();
        oc.childObjectApiName = 'Contact';
        oc.parentLookupFields = new List<String>{ 'Account.ParentId' };
        System.assertEquals(
            'Account.ParentId = :bindMainId',
            oc.whereParentEquals('bindMainId'));
        System.assert(
            oc.selectParentFields().contains('Account.ParentId'),
            oc.selectParentFields());
    }

    /**
     * @description Verifies OWD already grants.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testOwdAlreadyGrants() {
        SharingConfigService.resetCache();
        SharingConfigService.owdModelOverride.put('account', 'Read');
        System.assertEquals(true, SharingConfigService.owdAlreadyGrants('Account', 'Read'));
        System.assertEquals(false, SharingConfigService.owdAlreadyGrants('Account', 'Edit'));
        System.assertEquals(false, SharingConfigService.owdAlreadyGrants('Account', 'Create/Edit'));

        SharingConfigService.owdModelOverride.put('account', 'ReadWrite');
        System.assertEquals(true, SharingConfigService.owdAlreadyGrants('Account', 'Read'));
        System.assertEquals(true, SharingConfigService.owdAlreadyGrants('Account', 'Edit'));
        System.assertEquals(true, SharingConfigService.owdAlreadyGrants('Account', 'All'));

        SharingConfigService.owdModelOverride.put('account', 'Private');
        System.assertEquals(false, SharingConfigService.owdAlreadyGrants('Account', 'Read'));
        System.assertEquals(false, SharingConfigService.owdAlreadyGrants('Account', 'Edit'));

        SharingConfigService.owdModelOverride.put('account', 'ControlledByParent');
        System.assertEquals(false, SharingConfigService.owdAlreadyGrants('Account', 'Edit'));

        System.assertEquals(1, SharingConfigService.owdAccessRank('Read'));
        System.assertEquals(2, SharingConfigService.owdAccessRank('ReadWriteTransfer'));
        System.assertEquals(0, SharingConfigService.owdAccessRank('Private'));
        System.assertEquals(1, SharingConfigService.shareAccessRank('read'));
        System.assertEquals(2, SharingConfigService.shareAccessRank('Create/Edit'));
    }
}
