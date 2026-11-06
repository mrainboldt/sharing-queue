/**
 * @description Volume tests for the Queueable drain.
 *
 * DML *statements* stay bounded as both queue depth and share-row count grow.
 * Before bulkification, 50 ShareMainDirect rows did ~4 statements each (~200)
 * and hit Too many DML statements: 151. After bulkification the drain is one
 * share insert (N distinct ParentId×UserOrGroupId rows) plus complete/fail.
 *
 * Queue size alone is not enough: fake Source Ids build zero shares, and
 * identical mains collapse to one row. These tests also insert distinct mains
 * and related children × team members so Limits.getDmlRows() scales while
 * Limits.getDmlStatements() does not.
 *
 * Measure processClaimedCheapQueues after claim so compact/Batch kick are excluded.
 * Test.startTest() resets governors so setup DML is not counted.
 * @author Melissa Rainboldt
 */
@IsTest
private class SharingQueueVolumeTest {

    static final Integer VOLUME = SharingQueueService.QUEUEABLE_LIMIT;
    /** Team members per parent for related-record cartesian share volume. */
    static final Integer PRINCIPALS = 2;
    /** Upper bound for drain DML after claim. Not a linear function of VOLUME or share rows. */
    static final Integer DRAIN_DML_BUDGET = 12;
    /** Upper bound for drain SOQL after claim. Must stay flat vs VOLUME (not 1:1). */
    static final Integer DRAIN_SOQL_BUDGET = 20;
    static final String APP_GLS = 'GLS';

    /**
     * @description Inserts records shared by the tests in this class.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestSetup
    static void makeData() {
        JobCatalogService.seedCatalogOCC();
        insert new Team_Member_Config__c(
            Name = 'OCC TM',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Role_Field_Api_Name__c = 'Title',
            Access_Level_Field_Api_Name__c = 'LocaleSidKey',
            Use_Team_Member_Access_Level__c = true,
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        insert new Sharing_Object_Config__c(
            Name = 'OCC Account',
            Child_Object_Api_Name__c = 'Account',
            Parent_Lookup_Field_Api_Name__c = 'ParentId',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
    }

    /**
     * @description Clears static overrides and caches so the next test starts from a known state.
     * @author Melissa Rainboldt
     * @return void
     */
    private static void reset() {
        JobCatalogService.resetCache();
        SharingConfigService.resetCache();
        SharingQueueHandlerRegistry.resetCache();
        SharingQueueQueueable.resetEnqueueGuard();
    }

    /**
     * @description Returns the ShareMainDirect Job used by the test.
     * @author Melissa Rainboldt
     * @return The Job__c produced for this test.
     */
    private static Job__c mainDirectJob() {
        return JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            JobCatalogService.APP_APPLICATION1);
    }

    /**
     * @description Returns the related-record Job used by the test.
     * @author Melissa Rainboldt
     * @return The Job__c produced for this test.
     */
    private static Job__c relatedJob() {
        return JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            JobCatalogService.APP_APPLICATION1);
    }

    /**
     * @description Returns the fan-out Job used by the test.
     * @author Melissa Rainboldt
     * @return The Job__c produced for this test.
     */
    private static Job__c fanoutJob() {
        return JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER,
            JobCatalogService.APP_APPLICATION1);
    }

    /**
     * @description Builds a fake Account Id from the sequence number.
     * @author Melissa Rainboldt
     * @param n Sequence number used to build unique test data.
     * @return The text produced for this test.
     */
    private static String fakeAccountId(Integer n) {
        String suffix = String.valueOf(1000 + n);
        return '001000000000' + suffix.leftPad(3, '0');
    }

    /**
     * @description Builds a pending ShareMainDirect queue row.
     * @author Melissa Rainboldt
     * @param n Sequence number used to build unique test data.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c pendingMainDirect(Integer n) {
        return new Sharing_Queue__c(
            Trigger_Event__c          = JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            Main_Record_Id__c         = String.valueOf(UserInfo.getUserId()),
            Main_Object_Api_Name__c   = 'User',
            Source_Record_Id__c       = fakeAccountId(n),
            Source_Object_Api_Name__c = 'User',
            Application__c            = JobCatalogService.APP_APPLICATION1,
            Status__c                 = SharingQueueService.STATUS_PENDING,
            Is_Chain_Step__c          = false,
            Retry_Count__c            = 0,
            Job__c                    = mainDirectJob().Id
        );
    }

    /**
     * @description Builds a pending related-record queue row.
     * @author Melissa Rainboldt
     * @param n Sequence number used to build unique test data.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c pendingRelated(Integer n) {
        return new Sharing_Queue__c(
            Trigger_Event__c          = JobCatalogService.EVENT_RELATED_RECORD_CREATED,
            Main_Record_Id__c         = String.valueOf(UserInfo.getUserId()),
            Main_Object_Api_Name__c   = 'User',
            Source_Record_Id__c       = fakeAccountId(n),
            Source_Object_Api_Name__c = 'Account',
            Application__c            = JobCatalogService.APP_APPLICATION1,
            Status__c                 = SharingQueueService.STATUS_PENDING,
            Is_Chain_Step__c          = false,
            Retry_Count__c            = 0,
            Job__c                    = relatedJob().Id
        );
    }

    /**
     * @description Inserts teammate users.
     * @author Melissa Rainboldt
     * @param n Sequence number used to build unique test data.
     * @return The collection produced for this test.
     */
    private static List<User> insertTeammates(Integer n) {
        List<User> teammates = new List<User>();
        String uniq = String.valueOf(Datetime.now().getTime()) + UserInfo.getUserId();
        for (Integer i = 0; i < n; i++) {
            String token = uniq + String.valueOf(i);
            teammates.add(new User(
                Alias = ('v' + token).left(8),
                Email = 'vol' + token + '@example.com',
                EmailEncodingKey = 'UTF-8',
                LastName = 'Volume' + i,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = UserInfo.getProfileId(),
                TimeZoneSidKey = 'America/New_York',
                UserName = 'vol' + token + '@sharevol.test'
            ));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert teammates;
        }
        return teammates;
    }

    /**
     * @description Builds payload JSON with the user and Edit access.
     * @author Melissa Rainboldt
     * @param userId User or group Id for the share.
     * @return The text produced for this test.
     */
    private static String editPayloadJson(Id userId) {
        SharingQueueService.Payload payload = new SharingQueueService.Payload();
        payload.userOrGroupId = String.valueOf(userId);
        payload.accessLevel = 'Edit';
        return payload.toJson();
    }

    /**
     * @description Inserts main records that the volume drain will share.
     * @author Melissa Rainboldt
     * @param n Sequence number used to build unique test data.
     * @return The collection produced for this test.
     */
    private static List<Team_Member_Config__c> insertMainsToShare(Integer n) {
        List<Team_Member_Config__c> mains = new List<Team_Member_Config__c>();
        for (Integer i = 0; i < n; i++) {
            mains.add(new Team_Member_Config__c(
                Name = 'Vol Main ' + i,
                Team_Member_Object_Api_Name__c = 'User',
                Parent_Lookup_Field_Api_Name__c = 'Id',
                User_Field_Api_Name__c = 'Id',
                Role_Field_Api_Name__c = 'Title',
                Access_Level_Field_Api_Name__c = 'LocaleSidKey',
                Is_Active__c = false,
                Application__c = JobCatalogService.APP_APPLICATION1
            ));
        }
        insert mains;
        return mains;
    }

    /**
     * @description GLS Contact TMs on one Account. Related children are Team_Member_Config
     * rows whose Name stores the Account Id (text parent, same as formula-like
     * configs) so each child is a Private custom object with ParentId shares.
     * @author Melissa Rainboldt
     * @return void
     */
    private static void seedRelatedShareConfig() {
        insert new Team_Member_Config__c(
            Name = 'GLS TM Volume',
            Team_Member_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'AccountId',
            User_Field_Api_Name__c = 'OwnerId',
            Role_Field_Api_Name__c = 'Title',
            Access_Level_Field_Api_Name__c = 'Description',
            Active_Field_Api_Name__c = 'HasOptedOutOfEmail',
            Use_Team_Member_Access_Level__c = true,
            Is_Active__c = true,
            Application__c = APP_GLS
        );
        insert new Sharing_Object_Config__c(
            Name = 'GLS TMC children',
            Child_Object_Api_Name__c = 'Team_Member_Config__c',
            Parent_Lookup_Field_Api_Name__c = 'Name',
            Row_Cause_Api_Name__c = 'Manual',
            Is_Active__c = true,
            Application__c = APP_GLS
        );
        SharingConfigService.resetCache();
    }

    /**
     * @description Inserts an Account and a team member for each user.
     * @author Melissa Rainboldt
     * @param teammates Users inserted as team members.
     * @return The Account produced for this test.
     */
    private static Account insertParentWithTeamMembers(List<User> teammates) {
        Account parent = new Account(Name = 'Volume parent');
        insert parent;
        List<Contact> tms = new List<Contact>();
        for (Integer i = 0; i < teammates.size(); i++) {
            tms.add(new Contact(
                LastName = 'Volume TM ' + i,
                AccountId = parent.Id,
                OwnerId = teammates[i].Id,
                Description = 'Edit',
                HasOptedOutOfEmail = true
            ));
        }
        insert tms;
        return parent;
    }

    /**
     * @description Inserts related child rows under the parent.
     * @author Melissa Rainboldt
     * @param parentId Parent record Id.
     * @param n Sequence number used to build unique test data.
     * @return The collection produced for this test.
     */
    private static List<Team_Member_Config__c> insertRelatedChildren(
            Id parentId, Integer n) {
        String parentKey = String.valueOf(parentId);
        List<Team_Member_Config__c> children = new List<Team_Member_Config__c>();
        for (Integer i = 0; i < n; i++) {
            children.add(new Team_Member_Config__c(
                Name = parentKey,
                Team_Member_Object_Api_Name__c = 'User',
                Parent_Lookup_Field_Api_Name__c = 'Id',
                User_Field_Api_Name__c = 'Id',
                Role_Field_Api_Name__c = 'Title',
                Access_Level_Field_Api_Name__c = 'LocaleSidKey',
                Is_Active__c = false,
                Application__c = JobCatalogService.APP_APPLICATION1
            ));
        }
        insert children;
        return children;
    }

    /**
     * @description Builds a pending ShareMainDirect row for a real main record.
     * @author Melissa Rainboldt
     * @param main Main record the queue row points at.
     * @param payloadJson Serialized payload.
     * @param n Sequence number used to build unique test data.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c pendingMainDirectShare(
            Team_Member_Config__c main, String payloadJson, Integer n) {
        Sharing_Queue__c row = pendingMainDirect(n);
        row.Main_Record_Id__c = String.valueOf(main.Id);
        row.Main_Object_Api_Name__c = 'Team_Member_Config__c';
        row.Payload__c = payloadJson;
        return row;
    }

    /**
     * @description Builds a pending related-record row for the child.
     * @author Melissa Rainboldt
     * @param accountId Account Id used as the main record.
     * @param child Related child record.
     * @param n Sequence number used to build unique test data.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c pendingRelatedChild(
            Id accountId, Team_Member_Config__c child, Integer n) {
        Sharing_Queue__c row = pendingRelated(n);
        row.Main_Record_Id__c = String.valueOf(accountId);
        row.Main_Object_Api_Name__c = 'Account';
        row.Source_Record_Id__c = String.valueOf(child.Id);
        row.Source_Object_Api_Name__c = 'Team_Member_Config__c';
        row.Application__c = APP_GLS;
        return row;
    }

    /**
     * @description Counts manual shares for the parents and users.
     * @author Melissa Rainboldt
     * @param parentIds Parent record Ids whose sharing is in scope.
     * @param userIds User or group Ids to include. Null means every principal.
     * @return The count produced for this test.
     */
    private static Integer tmcManualShareCount(Set<Id> parentIds, Set<Id> userIds) {
        return [
            SELECT COUNT()
            FROM Team_Member_Config__Share
            WHERE ParentId IN :parentIds
            AND UserOrGroupId IN :userIds
            AND RowCause = 'Manual'
        ];
    }

    /**
     * @description Returns the Ids of the given records.
     * @author Melissa Rainboldt
     * @param records Source records for this operation.
     * @return The collection produced for this test.
     */
    private static Set<Id> idsOf(List<SObject> records) {
        Set<Id> ids = new Set<Id>();
        for (SObject rec : records) {
            ids.add(rec.Id);
        }
        return ids;
    }

    /**
     * @description Reloads the Sharing Queue rows from the database.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @return The collection produced for this test.
     */
    private static List<Sharing_Queue__c> requery(List<Sharing_Queue__c> rows) {
        return [
            SELECT Id, Trigger_Event__c, Job__c, Job__r.Handler__c, Job__r.Processor__c,
                   Job__r.Name, Main_Record_Id__c, Main_Object_Api_Name__c,
                   Source_Record_Id__c, Source_Object_Api_Name__c, Status__c,
                   Next_Queue__c, Retry_Count__c, Payload__c, Records_Processed__c,
                   Application__c
            FROM Sharing_Queue__c
            WHERE Id IN :rows
        ];
    }

    /**
     * @description DML statement and SOQL counts for one Queueable drain in a volume test.
     * @author Melissa Rainboldt
     */
    private class DrainUsage {
        Integer dml;
        Integer soql;
    }

    /**
     * @description Claim then drain. Returns DML/SOQL used by processClaimedCheapQueues only.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @return The count produced for this test.
     */
    private static Integer drainAfterClaim(List<Sharing_Queue__c> rows) {
        return drainAfterClaimUsage(rows).dml;
    }

    /**
     * @description Claims the rows and returns the DML and SOQL used by the drain.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @return The DrainUsage produced for this test.
     */
    private static DrainUsage drainAfterClaimUsage(List<Sharing_Queue__c> rows) {
        SharingQueueService.ClaimResult claimed =
            SharingQueueService.claimQueues(requery(rows), null);
        DrainUsage usage = new DrainUsage();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer soqlBefore = Limits.getQueries();
        SharingQueueService.processClaimedCheapQueues(claimed);
        usage.dml = Limits.getDmlStatements() - dmlBefore;
        usage.soql = Limits.getQueries() - soqlBefore;
        return usage;
    }

    /**
     * @description Asserts every queue row has the expected status.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @param status Status value expected on every row.
     * @return void
     */
    private static void assertAllStatus(List<Sharing_Queue__c> rows, String status) {
        for (Sharing_Queue__c row : [
            SELECT Status__c, Last_Error__c FROM Sharing_Queue__c WHERE Id IN :rows
        ]) {
            System.assertEquals(status, row.Status__c, row.Last_Error__c);
        }
    }

    /**
     * @description Asserts every queue row processed the expected number of records.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @param expected Expected Records Processed value.
     * @return void
     */
    private static void assertProcessed(List<Sharing_Queue__c> rows, Integer expected) {
        for (Sharing_Queue__c row : [
            SELECT Records_Processed__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id IN :rows
        ]) {
            System.assertEquals(
                expected,
                Integer.valueOf(row.Records_Processed__c),
                row.Last_Error__c);
        }
    }

    /**
     * @description Asserts the drain stayed within the DML bound for the share-row count.
     * @author Melissa Rainboldt
     * @param dml DML statement count measured for the drain.
     * @param shareRows Number of share rows the drain wrote.
     * @param label Text included when the assertion fails.
     * @return void
     */
    private static void assertDrainBounded(Integer dml, Integer shareRows, String label) {
        System.assert(
            dml <= DRAIN_DML_BUDGET,
            label + ' used ' + dml + ' DML statements for ' + shareRows
                + ' share rows (budget ' + DRAIN_DML_BUDGET + ')');
    }

    /**
     * @description Verifies main direct volume DML stays bounded.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMainDirectVolumeDmlStaysBounded() {
        reset();
        List<User> teammates = insertTeammates(1);
        List<Team_Member_Config__c> mains = insertMainsToShare(VOLUME);
        String json = editPayloadJson(teammates[0].Id);

        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        for (Integer i = 0; i < VOLUME; i++) {
            rows.add(pendingMainDirectShare(mains[i], json, i));
        }
        insert rows;

        Test.startTest();
        DrainUsage usage = drainAfterClaimUsage(rows);
        Test.stopTest();

        assertDrainBounded(usage.dml, VOLUME, 'ShareMainDirect distinct mains');
        System.assert(
            usage.soql <= DRAIN_SOQL_BUDGET,
            'ShareMainDirect drain SOQL must not grow 1:1 with ' + VOLUME
                + ' queue rows; used ' + usage.soql
                + ' (budget ' + DRAIN_SOQL_BUDGET + ')');
        assertAllStatus(rows, SharingQueueService.STATUS_COMPLETED);
        assertProcessed(rows, 1);
        System.assertEquals(
            VOLUME,
            tmcManualShareCount(idsOf(mains), new Set<Id>{ teammates[0].Id }),
            'Each queue must insert its own Main share, not skip or collapse');
    }

    /**
     * @description Verifies related record volume DML stays bounded.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedRecordVolumeDmlStaysBounded() {
        reset();
        seedRelatedShareConfig();
        List<User> teammates = insertTeammates(PRINCIPALS);
        Account parent = insertParentWithTeamMembers(teammates);
        List<Team_Member_Config__c> children = insertRelatedChildren(parent.Id, VOLUME);

        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        for (Integer i = 0; i < VOLUME; i++) {
            rows.add(pendingRelatedChild(parent.Id, children[i], i));
        }
        insert rows;

        Integer expectedShares = VOLUME * PRINCIPALS;
        Test.startTest();
        Integer dml = drainAfterClaim(rows);
        Test.stopTest();

        assertDrainBounded(dml, expectedShares, 'Related children × team members');
        assertAllStatus(rows, SharingQueueService.STATUS_COMPLETED);
        assertProcessed(rows, PRINCIPALS);
        System.assertEquals(
            expectedShares,
            tmcManualShareCount(idsOf(children), idsOf(teammates)),
            VOLUME + ' related records × ' + PRINCIPALS
                + ' team members should be one bulk share insert');
    }

    /**
     * @description Verifies mixed handlers volume DML stays bounded.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMixedHandlersVolumeDmlStaysBounded() {
        reset();
        seedRelatedShareConfig();
        List<User> teammates = insertTeammates(PRINCIPALS);
        List<Team_Member_Config__c> mains = insertMainsToShare(VOLUME / 2);
        String json = editPayloadJson(teammates[0].Id);
        Account parent = insertParentWithTeamMembers(teammates);
        List<Team_Member_Config__c> children = insertRelatedChildren(parent.Id, VOLUME / 2);

        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        for (Integer i = 0; i < mains.size(); i++) {
            rows.add(pendingMainDirectShare(mains[i], json, i));
        }
        for (Integer i = 0; i < children.size(); i++) {
            rows.add(pendingRelatedChild(parent.Id, children[i], 100 + i));
        }
        insert rows;

        Integer expectedShares = mains.size() + (children.size() * PRINCIPALS);
        Test.startTest();
        Integer dml = drainAfterClaim(rows);
        Test.stopTest();

        assertDrainBounded(dml, expectedShares, 'Mixed Main + related share volume');
        assertAllStatus(rows, SharingQueueService.STATUS_COMPLETED);
        System.assertEquals(
            mains.size(),
            tmcManualShareCount(idsOf(mains), new Set<Id>{ teammates[0].Id }));
        System.assertEquals(
            children.size() * PRINCIPALS,
            tmcManualShareCount(idsOf(children), idsOf(teammates)));
    }

    /**
     * @description Verifies successor activation is one update at volume.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testSuccessorActivationIsOneUpdateAtVolume() {
        reset();
        List<Sharing_Queue__c> successors = new List<Sharing_Queue__c>();
        Id fanoutId = fanoutJob().Id;
        for (Integer i = 0; i < VOLUME; i++) {
            Sharing_Queue__c nextRow = pendingRelated(i);
            nextRow.Job__c = fanoutId;
            nextRow.Status__c = SharingQueueService.STATUS_BLOCKED;
            nextRow.Is_Chain_Step__c = true;
            nextRow.Trigger_Event__c = JobCatalogService.EVENT_TEAM_MEMBER_CREATED;
            successors.add(nextRow);
        }
        insert successors;

        List<Sharing_Queue__c> heads = new List<Sharing_Queue__c>();
        for (Integer i = 0; i < VOLUME; i++) {
            Sharing_Queue__c head = pendingMainDirect(i);
            head.Next_Queue__c = successors[i].Id;
            heads.add(head);
        }
        insert heads;

        Test.startTest();
        Integer dml = drainAfterClaim(heads);
        Test.stopTest();

        System.assert(
            dml <= DRAIN_DML_BUDGET,
            'Activating ' + VOLUME + ' successors should be one update; used '
                + dml + ' statements');
        assertAllStatus(heads, SharingQueueService.STATUS_COMPLETED);
        assertAllStatus(successors, SharingQueueService.STATUS_PENDING);
    }

    /**
     * @description Verifies collapsed shares are one insert at volume.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testCollapsedSharesAreOneInsertAtVolume() {
        reset();
        Team_Member_Config__c main = [
            SELECT Id FROM Team_Member_Config__c
            WHERE Application__c = :JobCatalogService.APP_APPLICATION1
            LIMIT 1
        ];
        List<User> teammates = insertTeammates(1);
        String json = editPayloadJson(teammates[0].Id);

        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        for (Integer i = 0; i < VOLUME; i++) {
            rows.add(pendingMainDirectShare(main, json, i));
        }
        insert rows;

        Test.startTest();
        Integer dml = drainAfterClaim(rows);
        Test.stopTest();

        assertDrainBounded(dml, 1, 'Collapsed identical Main shares');
        assertAllStatus(rows, SharingQueueService.STATUS_COMPLETED);
        System.assertEquals(
            1,
            tmcManualShareCount(new Set<Id>{ main.Id }, new Set<Id>{ teammates[0].Id }),
            'Same ParentId+UserOrGroupId must collapse to one share row');
    }

    /**
     * @description Verifies queueable execute at volume does not hit DML governor.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testQueueableExecuteAtVolumeDoesNotHitDmlGovernor() {
        reset();
        List<User> teammates = insertTeammates(1);
        List<Team_Member_Config__c> mains = insertMainsToShare(VOLUME);
        String json = editPayloadJson(teammates[0].Id);

        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        for (Integer i = 0; i < VOLUME; i++) {
            rows.add(pendingMainDirectShare(mains[i], json, i));
        }
        insert rows;

        Test.startTest();
        new SharingQueueQueueable().execute(null);
        Integer dml = Limits.getDmlStatements();
        Test.stopTest();

        System.assert(
            dml < 40,
            'Full Queueable.execute on ' + VOLUME
                + ' distinct Main shares must stay under the 150 DML cap; used '
                + dml);
        assertAllStatus(rows, SharingQueueService.STATUS_COMPLETED);
        System.assertEquals(
            VOLUME,
            tmcManualShareCount(idsOf(mains), new Set<Id>{ teammates[0].Id }));
    }
}
