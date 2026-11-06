/**
 * @description VolumeHarness consumer: Sharing Queue at VOLUME (originating vs workers vs total).
 * Catalog Jobs are OCC; GLS-shaped Contact TM + TMC children use Application
 * GLS with a GLS catalog clone so enqueue can resolve head jobs.
 * @author Melissa Rainboldt
 */
@IsTest
private class SharingVolumeCompareTest {

    static final Integer VOLUME = SharingQueueService.QUEUEABLE_LIMIT;
    static final Integer PRINCIPALS = 2;
    static final String APP_GLS = 'GLS';

    /**
     * @description Inserts records shared by the tests in this class.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestSetup
    static void makeData() {
        JobCatalogService.seedCatalogOCC();
        seedGlsCatalog();
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
    }

    /**
     * @description Inserts the GLS job catalog used by the compare tests.
     * @author Melissa Rainboldt
     * @return void
     */
    private static void seedGlsCatalog() {
        Job__c shareMain = new Job__c(
            Name = 'GLS ' + JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            Handler__c = JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            Processor__c = JobCatalogService.PROCESSOR_QUEUEABLE,
            Application__c = APP_GLS,
            Is_Active__c = true
        );
        Job__c shareAll = new Job__c(
            Name = 'GLS ' + JobCatalogService.HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER,
            Handler__c = JobCatalogService.HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER,
            Processor__c = JobCatalogService.PROCESSOR_BATCH,
            Application__c = APP_GLS,
            Is_Active__c = true
        );
        Job__c shareRelated = new Job__c(
            Name = 'GLS ' + JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            Handler__c = JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            Processor__c = JobCatalogService.PROCESSOR_QUEUEABLE,
            Application__c = APP_GLS,
            Is_Active__c = true
        );
        insert new List<Job__c>{ shareMain, shareAll, shareRelated };
        shareMain.Next_Job__c = shareAll.Id;
        update shareMain;
        insert new List<Job_Trigger_Event__c>{
            glsMapping(JobCatalogService.EVENT_TEAM_MEMBER_CREATED, shareMain.Id),
            glsMapping(JobCatalogService.EVENT_TEAM_MEMBER_UPDATED, shareMain.Id),
            glsMapping(JobCatalogService.EVENT_RELATED_RECORD_CREATED, shareRelated.Id)
        };
    }

    /**
     * @description Builds a GLS job trigger-event mapping.
     * @author Melissa Rainboldt
     * @param event Trigger event key.
     * @param jobId Job Id.
     * @return The Job_Trigger_Event__c produced for this test.
     */
    private static Job_Trigger_Event__c glsMapping(String event, Id jobId) {
        return new Job_Trigger_Event__c(
            Name = 'GLS ' + event,
            Job__c = jobId,
            Trigger_Event__c = event,
            Event_Key__c = 'GLS.' + event,
            Is_Active__c = true,
            Application__c = APP_GLS
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
        SharingQueueService.suppressAsyncKick = false;
    }

    /**
     * @description Returns the volume engine selected by the compare flag.
     * @author Melissa Rainboldt
     * @param operation Volume operation or DML verb for this call.
     * @param objectApiName API name of the sObject.
     * @param records Source records for this operation.
     * @param oldMap Prior records keyed by Id. Null on insert.
     * @return The VolumeEngine produced for this test.
     */
    private static VolumeEngine engine(
            SharingQueueVolumeEngine.Op operation,
            String objectApiName,
            List<SObject> records,
            Map<Id, SObject> oldMap) {
        return new SharingQueueVolumeEngine(
            operation, APP_GLS, objectApiName, records, oldMap);
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
                Alias = ('c' + token).left(8),
                Email = 'cmp' + token + '@example.com',
                EmailEncodingKey = 'UTF-8',
                LastName = 'Compare' + i,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = UserInfo.getProfileId(),
                TimeZoneSidKey = 'America/New_York',
                UserName = 'cmp' + token + '@sharevol.test'
            ));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert teammates;
        }
        return teammates;
    }

    /**
     * @description Inserts an Account.
     * @author Melissa Rainboldt
     * @param name Name used by this call.
     * @return The Account produced for this test.
     */
    private static Account insertAccount(String name) {
        Account parent = new Account(Name = name);
        insert parent;
        return parent;
    }

    /**
     * @description Inserts team member contacts on the Account.
     * @author Melissa Rainboldt
     * @param accountId Account Id used as the main record.
     * @param teammates Users inserted as team members.
     * @return The collection produced for this test.
     */
    private static List<Contact> insertTeamMembers(Id accountId, List<User> teammates) {
        List<Contact> tms = new List<Contact>();
        for (Integer i = 0; i < teammates.size(); i++) {
            tms.add(newContact(accountId, teammates[i].Id, 'Edit', i));
        }
        insert tms;
        return tms;
    }

    /**
     * @description Builds an unsaved team member contact.
     * @author Melissa Rainboldt
     * @param accountId Account Id used as the main record.
     * @param ownerId User Id that owns the team member contact.
     * @param accessLevel Share or team-member access level.
     * @param n Sequence number used to build unique test data.
     * @return The Contact produced for this test.
     */
    private static Contact newContact(Id accountId, Id ownerId, String accessLevel, Integer n) {
        return new Contact(
            LastName = 'Compare TM ' + n,
            AccountId = accountId,
            OwnerId = ownerId,
            Description = accessLevel,
            HasOptedOutOfEmail = true
        );
    }

    /**
     * @description Builds unsaved related child rows.
     * @author Melissa Rainboldt
     * @param parentId Parent record Id.
     * @param n Sequence number used to build unique test data.
     * @return The collection produced for this test.
     */
    private static List<Team_Member_Config__c> newChildren(Id parentId, Integer n) {
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
        return children;
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
     * @description Asserts no Sharing Queue row failed.
     * @author Melissa Rainboldt
     * @return void
     */
    private static void assertNoFailedQueues() {
        Integer failed = [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Status__c = :SharingQueueService.STATUS_FAILED
        ];
        System.assertEquals(0, failed, 'Sharing Queue rows should not fail at volume');
        Integer open = [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Status__c IN (
                :SharingQueueService.STATUS_PENDING,
                :SharingQueueService.STATUS_PROCESSING,
                :SharingQueueService.STATUS_BLOCKED
            )
        ];
        System.assertEquals(0, open, 'Workers should drain all open Sharing Queue rows');
    }

    /**
     * @description Volume DML (insert/update) plus engine.run() is originating; drainOnce is
     * workers.
     * @author Melissa Rainboldt
     * @param scenario Label printed on the volume report.
     * @param engine Volume engine whose run and drainOnce are measured.
     * @param toInsert Records inserted before the engine runs and counted as originating work.
     * @param toUpdate Records updated before the engine runs and counted as originating work.
     * @return The VolumeReport produced for this test.
     */
    private static VolumeReport measureWithDml(
            String scenario,
            VolumeEngine engine,
            List<SObject> toInsert,
            List<SObject> toUpdate) {
        Test.startTest();
        VolumeLimits before = VolumeLimits.capture();
        if (toInsert != null && !toInsert.isEmpty()) insert toInsert;
        if (toUpdate != null && !toUpdate.isEmpty()) update toUpdate;
        VolumeLimits dmlSlice = VolumeLimits.capture().diff(before);
        VolumeReport report = VolumeHarness.measure(scenario, engine);
        report.originating = dmlSlice.add(report.originating);
        report.total = report.originating.copy().add(report.workers);
        System.debug(LoggingLevel.WARN, report.toLine());
        Test.stopTest();
        return report;
    }

    /**
     * @description Verifies related created.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedCreated() {
        reset();
        List<User> teammates = insertTeammates(PRINCIPALS);
        Account parent = insertAccount('Compare related create');
        insertTeamMembers(parent.Id, teammates);
        List<Team_Member_Config__c> children = newChildren(parent.Id, VOLUME);

        VolumeReport report = measureWithDml(
            'RelatedCreated',
            engine(
                SharingQueueVolumeEngine.Op.RELATED_CREATED,
                'Team_Member_Config__c',
                children,
                null),
            children,
            null);

        System.assertNotEquals(null, report.total);
        assertNoFailedQueues();
        System.assertEquals(
            VOLUME * PRINCIPALS,
            tmcManualShareCount(idsOf(children), idsOf(teammates)));
        System.assert(report.workerCalls >= 1, 'Related create should drain Queueable');
    }

    /**
     * @description Verifies related updated.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedUpdated() {
        reset();
        List<User> teammates = insertTeammates(PRINCIPALS);
        Account fromParent = insertAccount('Compare related from');
        Account toParent = insertAccount('Compare related to');
        insertTeamMembers(fromParent.Id, teammates);
        insertTeamMembers(toParent.Id, teammates);
        List<Team_Member_Config__c> children = newChildren(fromParent.Id, VOLUME);
        insert children;
        for (Team_Member_Config__c child : children) {
            child.Name = String.valueOf(toParent.Id);
        }

        VolumeReport report = measureWithDml(
            'RelatedUpdated',
            engine(
                SharingQueueVolumeEngine.Op.RELATED_UPDATED,
                'Team_Member_Config__c',
                children,
                null),
            null,
            children);

        System.assertNotEquals(null, report.total);
        assertNoFailedQueues();
        System.assertEquals(
            VOLUME * PRINCIPALS,
            tmcManualShareCount(idsOf(children), idsOf(teammates)),
            'Related update enqueues RelatedRecordCreated for the new parent');
        System.assert(report.workerCalls >= 1, 'Related update should drain Queueable');
    }

    /**
     * @description Verifies team members created.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testTeamMembersCreated() {
        reset();
        SharingConfigService.owdModelOverride.put('account', 'ReadWrite');
        List<User> teammates = insertTeammates(PRINCIPALS);
        Account parent = insertAccount('Compare TM create');
        List<Team_Member_Config__c> children = newChildren(parent.Id, VOLUME);
        insert children;
        List<Contact> tms = new List<Contact>();
        for (Integer i = 0; i < VOLUME; i++) {
            tms.add(newContact(
                parent.Id,
                teammates[Math.mod(i, PRINCIPALS)].Id,
                'Edit',
                i));
        }

        VolumeReport report = measureWithDml(
            'TeamMemberCreated',
            engine(
                SharingQueueVolumeEngine.Op.TEAM_MEMBER_CREATED,
                'Contact',
                tms,
                null),
            tms,
            null);

        System.assertNotEquals(null, report.total);
        assertNoFailedQueues();
        System.assertEquals(
            VOLUME * PRINCIPALS,
            tmcManualShareCount(idsOf(children), idsOf(teammates)));
        System.assert(
            report.workerCalls >= 1,
            'TM create should drain Queueable and Batch fan-out');
    }

    /**
     * @description Verifies team members updated.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testTeamMembersUpdated() {
        reset();
        SharingConfigService.owdModelOverride.put('account', 'ReadWrite');
        List<User> teammates = insertTeammates(PRINCIPALS);
        Account parent = insertAccount('Compare TM update');
        List<Team_Member_Config__c> children = newChildren(parent.Id, VOLUME);
        insert children;
        List<Contact> tms = new List<Contact>();
        for (Integer i = 0; i < VOLUME; i++) {
            tms.add(newContact(
                parent.Id,
                teammates[Math.mod(i, PRINCIPALS)].Id,
                'Edit',
                i));
        }
        insert tms;
        Map<Id, SObject> oldMap = new Map<Id, SObject>();
        for (Contact tm : tms) {
            oldMap.put(tm.Id, tm.clone(true, true, false, false));
            tm.Description = 'Read';
        }

        VolumeReport report = measureWithDml(
            'TeamMemberUpdated',
            engine(
                SharingQueueVolumeEngine.Op.TEAM_MEMBER_UPDATED,
                'Contact',
                tms,
                oldMap),
            null,
            tms);

        System.assertNotEquals(null, report.total);
        assertNoFailedQueues();
        System.assert(report.workerCalls >= 1, 'TM update should drain workers');
    }
}
