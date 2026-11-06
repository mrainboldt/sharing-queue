/**
 * @description ShareMainDirect inserts one Apex-managed share on Main for the new Team Member.
 * @author Melissa Rainboldt
 */
@IsTest
private class ShareMainDirectTest {

    private static final String APP = 'GLS';

    /**
     * @description Inserts records shared by the tests in this class.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestSetup
    static void makeData() {
        insert new Team_Member_Config__c(
            Name = 'GLS TM',
            Team_Member_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'AccountId',
            User_Field_Api_Name__c = 'OwnerId',
            Access_Level_Field_Api_Name__c = 'Description',
            Active_Field_Api_Name__c = 'HasOptedOutOfEmail',
            Use_Team_Member_Access_Level__c = true,
            Is_Active__c = true,
            Application__c = APP
        );
        insert new Sharing_Object_Config__c(
            Name = 'GLS related Account',
            Child_Object_Api_Name__c = 'Account',
            Parent_Lookup_Field_Api_Name__c = 'ParentId',
            Row_Cause_Api_Name__c = 'TeamMemberAccess__c',
            Is_Active__c = true,
            Application__c = APP
        );
    }

    /**
     * @description Inserts one teammate user.
     * @author Melissa Rainboldt
     * @return The User produced for this test.
     */
    private static User insertTeammate() {
        User member = teammate();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert member;
        }
        return member;
    }

    /**
     * @description Returns the teammate user.
     * @author Melissa Rainboldt
     * @return The User produced for this test.
     */
    private static User teammate() {
        String uniq = String.valueOf(Datetime.now().getTime()) + UserInfo.getUserId();
        return new User(
            Alias = ('tm' + uniq).left(8),
            Email = 'tm' + uniq + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Teammate',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/New_York',
            UserName = 'tm' + uniq + '@sharemain.test'
        );
    }

    /**
     * @description Returns the main record used as the share parent.
     * @author Melissa Rainboldt
     * @return The Team_Member_Config__c produced for this test.
     */
    private static Team_Member_Config__c mainRecord() {
        return [
            SELECT Id
            FROM Team_Member_Config__c
            WHERE Application__c = :APP
            LIMIT 1
        ];
    }

    /**
     * @description Builds a Sharing Queue row for the main, source, and payload.
     * @author Melissa Rainboldt
     * @param mainId Main record Id.
     * @param sourceId Source record Id, such as a team member or child.
     * @param payload Queue payload carrying principal, access, related objects, and cursor.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c queueFor(Id mainId, Id sourceId, SharingQueueService.Payload payload) {
        return new Sharing_Queue__c(
            Trigger_Event__c          = JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            Main_Record_Id__c         = String.valueOf(mainId),
            Main_Object_Api_Name__c   = 'Team_Member_Config__c',
            Source_Record_Id__c       = sourceId == null ? null : String.valueOf(sourceId),
            Source_Object_Api_Name__c = 'Contact',
            Application__c            = APP,
            Status__c                 = SharingQueueService.STATUS_PENDING,
            Payload__c                = payload == null ? null : payload.toJson()
        );
    }

    /**
     * @description Counts manual shares for the main and user.
     * @author Melissa Rainboldt
     * @param mainId Main record Id.
     * @param userId User or group Id for the share.
     * @return The count produced for this test.
     */
    private static Integer shareCount(Id mainId, Id userId) {
        return [
            SELECT COUNT()
            FROM Team_Member_Config__Share
            WHERE ParentId = :mainId
            AND UserOrGroupId = :userId
            AND RowCause = 'Manual'
        ];
    }

    /**
     * @description Verifies shares main when team member created.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testSharesMainWhenTeamMemberCreated() {
        SharingConfigService.resetCache();
        User member = insertTeammate();

        Account account = new Account(Name = 'Main Account');
        insert account;
        Contact tm = new Contact(
            LastName = 'Member',
            AccountId = account.Id,
            OwnerId = member.Id,
            Description = 'Create/Edit',
            HasOptedOutOfEmail = false
        );
        insert tm;

        Team_Member_Config__c main = mainRecord();
        SharingQueueService.Payload payload = new SharingQueueService.Payload();
        payload.userOrGroupId = String.valueOf(member.Id);
        payload.rowCause = 'TeamMemberAccess__c';

        Test.startTest();
        Integer processed = new ShareMainDirect().process(queueFor(main.Id, tm.Id, payload));
        Test.stopTest();

        System.assertEquals(1, processed, 'ShareMainDirect should insert the Main share');
        System.assertEquals(1, shareCount(main.Id, member.Id));
        Team_Member_Config__Share share = [
            SELECT AccessLevel, RowCause
            FROM Team_Member_Config__Share
            WHERE ParentId = :main.Id
            AND UserOrGroupId = :member.Id
            LIMIT 1
        ];
        System.assertEquals('Edit', share.AccessLevel);
        System.assertEquals(
            'Manual',
            share.RowCause,
            'Main must use Manual, not the related-object RowCause on the payload');
    }

    /**
     * @description Verifies uses payload when team member is missing.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testUsesPayloadWhenTeamMemberIsMissing() {
        SharingConfigService.resetCache();
        User member = insertTeammate();
        Team_Member_Config__c main = mainRecord();
        Account stray = new Account(Name = 'Not a team member');
        insert stray;

        SharingQueueService.Payload payload = new SharingQueueService.Payload();
        payload.userOrGroupId = String.valueOf(member.Id);
        payload.accessLevel = 'Read';

        Integer processed = new ShareMainDirect().process(queueFor(main.Id, stray.Id, payload));

        System.assertEquals(1, processed);
        System.assertEquals(1, shareCount(main.Id, member.Id));
    }

    /**
     * @description Verifies skips when access level cannot be resolved.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testSkipsWhenAccessLevelCannotBeResolved() {
        SharingConfigService.resetCache();
        User member = insertTeammate();

        Account account = new Account(Name = 'Main Account');
        insert account;
        Contact tm = new Contact(
            LastName = 'No Access',
            AccountId = account.Id,
            OwnerId = member.Id,
            Description = 'NotALevel',
            HasOptedOutOfEmail = false
        );
        insert tm;

        Team_Member_Config__c main = mainRecord();
        Integer processed = new ShareMainDirect().process(queueFor(main.Id, tm.Id, null));

        System.assertEquals(0, processed);
        System.assertEquals(0, shareCount(main.Id, member.Id));
    }

    /**
     * @description Verifies enqueue from team members stamps access and main row cause.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testEnqueueFromTeamMembersStampsAccessAndMainRowCause() {
        SharingConfigService.resetCache();
        User member = insertTeammate();

        Account account = new Account(Name = 'Main Account');
        insert account;
        Contact tm = new Contact(
            LastName = 'Member',
            AccountId = account.Id,
            OwnerId = member.Id,
            Description = 'Edit',
            HasOptedOutOfEmail = false
        );
        insert tm;

        Integer enqueued = SharingQueueService.enqueueFromTeamMembers(
            new List<SObject>{ tm },
            null,
            JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            APP);
        System.assertEquals(1, enqueued);

        Sharing_Queue__c row = [
            SELECT Payload__c, Main_Record_Id__c, Source_Record_Id__c
            FROM Sharing_Queue__c
            WHERE Source_Record_Id__c = :String.valueOf(tm.Id)
            LIMIT 1
        ];
        SharingQueueService.Payload payload = SharingQueueService.parsePayload(row.Payload__c);
        System.assertEquals(String.valueOf(member.Id), payload.userOrGroupId);
        System.assertEquals('Edit', payload.accessLevel);
        System.assertEquals(
            'Manual',
            payload.rowCause,
            'Payload RowCause for Main must not be the related Account Apex reason');
        System.assertEquals(String.valueOf(account.Id), row.Main_Record_Id__c);
    }

    /**
     * @description Verifies drain SOQL does not scale with queue rows.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testDrainSoqlDoesNotScaleWithQueueRows() {
        SharingConfigService.resetCache();
        SharingQueueHandlerRegistry.resetCache();
        Job__c job = new Job__c(
            Name = 'ShareMainDirect',
            Handler__c = JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            Processor__c = JobCatalogService.PROCESSOR_QUEUEABLE,
            Application__c = APP,
            Is_Active__c = true
        );
        insert job;

        Team_Member_Config__c main = mainRecord();
        Account account = new Account(Name = 'Drain Account');
        insert account;
        Integer n = 10;
        List<Contact> tms = new List<Contact>();
        for (Integer i = 0; i < n; i++) {
            tms.add(new Contact(
                LastName = 'Drain ' + i,
                AccountId = account.Id,
                OwnerId = UserInfo.getUserId(),
                Description = 'Edit',
                HasOptedOutOfEmail = false
            ));
        }
        insert tms;

        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        for (Contact tm : tms) {
            Sharing_Queue__c row = queueFor(main.Id, tm.Id, null);
            row.Job__c = job.Id;
            rows.add(row);
        }
        insert rows;

        List<Sharing_Queue__c> loaded = [
            SELECT Id, Trigger_Event__c, Job__c, Job__r.Handler__c, Job__r.Processor__c,
                   Job__r.Name, Main_Record_Id__c, Main_Object_Api_Name__c,
                   Source_Record_Id__c, Source_Object_Api_Name__c, Status__c,
                   Next_Queue__c, Retry_Count__c, Payload__c, Records_Processed__c,
                   Application__c
            FROM Sharing_Queue__c
            WHERE Id IN :rows
        ];
        SharingConfigService.getInstance(APP);

        Test.startTest();
        SharingQueueService.ClaimResult claimed =
            SharingQueueService.claimQueues(loaded, null);
        Integer before = Limits.getQueries();
        SharingQueueService.processClaimedCheapQueues(claimed);
        Integer soql = Limits.getQueries() - before;
        Test.stopTest();

        System.assert(
            soql < n,
            'Drain SOQL must not be 1:1 with queue rows; used ' + soql + ' for ' + n);
        System.assert(
            soql <= 12,
            'ShareMainDirect drain should be one TM query plus bounded extras; used '
                + soql);
        for (Sharing_Queue__c row : [
            SELECT Status__c, Last_Error__c FROM Sharing_Queue__c WHERE Id IN :rows
        ]) {
            System.assertEquals(
                SharingQueueService.STATUS_COMPLETED, row.Status__c, row.Last_Error__c);
        }
        System.assertEquals(1, shareCount(main.Id, UserInfo.getUserId()));
    }

    /**
     * @description Verifies reconcile drops the main share for an inactive principal and keeps
     * the share for an active principal.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testUnshareDropsInactivePrincipalOnMain() {
        User activeUser = insertLabeledTeammate('active');
        User inactiveUser = insertLabeledTeammate('inactive');

        insert new Team_Member_Config__c(
            Name = 'TAS TM',
            Team_Member_Object_Api_Name__c = 'Team_Member_Config__c',
            Parent_Lookup_Field_Api_Name__c = 'Name',
            User_Field_Api_Name__c = 'OwnerId',
            Role_Field_Api_Name__c = 'Team_Member_Object_Api_Name__c',
            Access_Level_Field_Api_Name__c = 'Access_Level_Field_Api_Name__c',
            Active_Field_Api_Name__c = 'Use_Team_Member_Access_Level__c',
            Use_Team_Member_Access_Level__c = false,
            Is_Active__c = true,
            Application__c = 'TAS'
        );
        Team_Member_Config__c main = new Team_Member_Config__c(
            Name = 'Main to share',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Role_Field_Api_Name__c = 'Title',
            Access_Level_Field_Api_Name__c = 'LocaleSidKey',
            Is_Active__c = false
        );
        insert main;
        insert new List<Team_Member_Config__c>{
            teamMemberRow(main.Id, activeUser.Id, true),
            teamMemberRow(main.Id, inactiveUser.Id, false)
        };
        insert new List<Team_Member_Config__Share>{
            manualShare(main.Id, activeUser.Id),
            manualShare(main.Id, inactiveUser.Id)
        };
        SharingConfigService.resetCache();

        Sharing_Queue__c queue = new Sharing_Queue__c(
            Application__c = 'TAS',
            Main_Record_Id__c = String.valueOf(main.Id),
            Main_Object_Api_Name__c = 'Team_Member_Config__c',
            Trigger_Event__c = JobCatalogService.EVENT_TEAM_MEMBER_DELETED,
            Status__c = SharingQueueService.STATUS_PENDING
        );

        Test.startTest();
        SharingQueueService.unshareInactivePrincipalsOnMain(
            new List<Sharing_Queue__c>{ queue });
        Test.stopTest();

        System.assertEquals(1, shareCount(main.Id, activeUser.Id));
        System.assertEquals(0, shareCount(main.Id, inactiveUser.Id));
    }

    /**
     * @description Inserts a teammate user with a unique label.
     * @author Melissa Rainboldt
     * @param label Label mixed into the username so two users in one test stay unique.
     * @return The User produced for this test.
     */
    private static User insertLabeledTeammate(String label) {
        String uniq = label + String.valueOf(Datetime.now().getTime()) + UserInfo.getUserId();
        User member = new User(
            Alias = (label + uniq).left(8),
            Email = label + uniq + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Teammate',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/New_York',
            UserName = label + uniq + '@sharemain.test'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert member;
        }
        return member;
    }

    /**
     * @description Builds a team-member row whose Name is the main Id.
     * @author Melissa Rainboldt
     * @param mainId Main record Id stored in Name so queryTeamMembers can find the row.
     * @param ownerId User Id that owns the team member row.
     * @param active True when Use Team Member Access Level marks the row active.
     * @return The Team_Member_Config__c produced for this test.
     */
    private static Team_Member_Config__c teamMemberRow(Id mainId, Id ownerId, Boolean active) {
        return new Team_Member_Config__c(
            Name = String.valueOf(mainId),
            OwnerId = ownerId,
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Role_Field_Api_Name__c = 'Title',
            Access_Level_Field_Api_Name__c = 'LocaleSidKey',
            Use_Team_Member_Access_Level__c = active,
            Is_Active__c = false
        );
    }

    /**
     * @description Builds a Manual share on the main for one user.
     * @author Melissa Rainboldt
     * @param mainId Main record Id.
     * @param userId User or group Id for the share.
     * @return The Team_Member_Config__Share produced for this test.
     */
    private static Team_Member_Config__Share manualShare(Id mainId, Id userId) {
        return new Team_Member_Config__Share(
            ParentId = mainId,
            UserOrGroupId = userId,
            AccessLevel = 'Edit',
            RowCause = 'Manual'
        );
    }
}
