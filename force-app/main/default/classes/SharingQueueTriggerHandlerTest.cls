/**
 * @description The handler is after-insert only: event rows (Job blank) are expanded via
 * SharingQueueService.expandChains. Inserting Sharing_Queue__c also covers the
 * trigger when it is deployed; a second afterInsert is a no-op once Job is set.
 * @author Melissa Rainboldt
 */
@IsTest
private class SharingQueueTriggerHandlerTest {

    /**
     * @description Inserts records shared by the tests in this class.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestSetup
    static void makeData() {
        JobCatalogService.seedCatalogOCC();
    }

    /**
     * @description Clears static overrides and caches so the next test starts from a known state.
     * @author Melissa Rainboldt
     * @return void
     */
    private static void reset() {
        JobCatalogService.resetCache();
        SharingQueueQueueable.resetEnqueueGuard();
    }

    /**
     * @description Builds an event-only Sharing Queue row for the trigger event.
     * @author Melissa Rainboldt
     * @param triggerEvent Trigger event key used to resolve the head Job.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c eventRow(String triggerEvent) {
        return new Sharing_Queue__c(
            Trigger_Event__c        = triggerEvent,
            Main_Record_Id__c       = String.valueOf(UserInfo.getUserId()),
            Main_Object_Api_Name__c = 'User',
            Source_Record_Id__c     = String.valueOf(UserInfo.getUserId()),
            Source_Object_Api_Name__c = 'User',
            Status__c               = SharingQueueService.STATUS_PENDING,
            Is_Chain_Step__c        = false,
            Retry_Count__c          = 0,
            Application__c           = 'OCC'
        );
    }

    /**
     * @description Reloads the Sharing Queue rows from the database.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @return The collection produced for this test.
     */
    private static List<Sharing_Queue__c> requery(List<Sharing_Queue__c> rows) {
        return [
            SELECT Id, Job__c, Job__r.Handler__c, Status__c, Next_Queue__c,
                   Trigger_Event__c, Main_Record_Id__c, Main_Object_Api_Name__c,
                   Source_Record_Id__c, Source_Object_Api_Name__c,
                   Is_Chain_Step__c, Payload__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id IN :rows
        ];
    }

    /**
     * @description Runs the after-insert handler for the rows.
     * @author Melissa Rainboldt
     * @param rows Queue rows to update.
     * @return void
     */
    private static void expand(List<Sharing_Queue__c> rows) {
        SharingQueueTriggerHandler.afterInsert(requery(rows));
    }

    /**
     * @description Verifies after insert empty list is no op.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testAfterInsertEmptyListIsNoOp() {
        reset();
        SharingQueueTriggerHandler.afterInsert(new List<Sharing_Queue__c>());
        System.assertEquals(0, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies team member created expands head and blocked successor.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testTeamMemberCreatedExpandsHeadAndBlockedSuccessor() {
        reset();
        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_TEAM_MEMBER_CREATED);
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c head = [
            SELECT Status__c, Job__r.Handler__c, Next_Queue__c, Trigger_Event__c,
                   Is_Chain_Step__c, Main_Record_Id__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, head.Status__c);
        System.assertEquals(JobCatalogService.HANDLER_SHARE_MAIN_DIRECT, head.Job__r.Handler__c);
        System.assertEquals(false, head.Is_Chain_Step__c);
        System.assertNotEquals(null, head.Next_Queue__c);

        Sharing_Queue__c successor = [
            SELECT Status__c, Job__r.Handler__c, Is_Chain_Step__c, Trigger_Event__c,
                   Next_Queue__c, Main_Record_Id__c, Application__c
            FROM Sharing_Queue__c
            WHERE Id = :head.Next_Queue__c
        ];
        System.assertEquals(SharingQueueService.STATUS_BLOCKED, successor.Status__c);
        System.assertEquals(
            JobCatalogService.HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER,
            successor.Job__r.Handler__c);
        System.assertEquals(true, successor.Is_Chain_Step__c);
        System.assertEquals(JobCatalogService.EVENT_TEAM_MEMBER_CREATED, successor.Trigger_Event__c);
        System.assertEquals(head.Main_Record_Id__c, successor.Main_Record_Id__c);
        System.assertEquals(JobCatalogService.APP_APPLICATION1, successor.Application__c);
        System.assertEquals(null, successor.Next_Queue__c);
    }

    /**
     * @description Verifies team member created stop test completes batch successor.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testTeamMemberCreatedStopTestCompletesBatchSuccessor() {
        reset();
        insert new Team_Member_Config__c(
            Name = 'OCC TM',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Role_Field_Api_Name__c = 'Title',
            Access_Level_Field_Api_Name__c = 'LocaleSidKey',
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
        SharingConfigService.resetCache();

        Account main = new Account(Name = 'Main');
        insert main;
        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_TEAM_MEMBER_CREATED);
        event.Main_Record_Id__c = String.valueOf(main.Id);
        event.Main_Object_Api_Name__c = 'Account';
        SharingQueueService.Payload payload = new SharingQueueService.Payload();
        payload.userOrGroupId = String.valueOf(UserInfo.getUserId());
        event.Payload__c = payload.toJson();

        Test.startTest();
        insert event;
        Test.stopTest();

        Sharing_Queue__c head = [
            SELECT Status__c, Job__r.Handler__c, Next_Queue__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(
            SharingQueueService.STATUS_COMPLETED,
            head.Status__c,
            head.Last_Error__c);
        System.assertEquals(JobCatalogService.HANDLER_SHARE_MAIN_DIRECT, head.Job__r.Handler__c);

        Sharing_Queue__c successor = [
            SELECT Status__c, Job__r.Handler__c, Job__r.Processor__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :head.Next_Queue__c
        ];
        System.assertEquals(
            JobCatalogService.HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER,
            successor.Job__r.Handler__c);
        System.assertEquals(
            SharingQueueService.STATUS_COMPLETED,
            successor.Status__c,
            successor.Last_Error__c);
    }

    /**
     * @description Verifies related record created is terminal queueable step.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedRecordCreatedIsTerminalQueueableStep() {
        reset();
        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_RELATED_RECORD_CREATED);
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c row = [
            SELECT Status__c, Job__r.Handler__c, Next_Queue__c, Is_Chain_Step__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, row.Status__c);
        System.assertEquals(
            JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            row.Job__r.Handler__c);
        System.assertEquals(null, row.Next_Queue__c);
        System.assertEquals(1, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies chain step insert is not expanded again.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testChainStepInsertIsNotExpandedAgain() {
        reset();
        Job__c fanout = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_ALL_RELATED_TO_TEAM_MEMBER,
            JobCatalogService.APP_APPLICATION1);
        Sharing_Queue__c chainStep = eventRow(JobCatalogService.EVENT_TEAM_MEMBER_CREATED);
        chainStep.Is_Chain_Step__c = true;
        chainStep.Job__c = fanout.Id;
        chainStep.Status__c = SharingQueueService.STATUS_BLOCKED;
        insert chainStep;
        expand(new List<Sharing_Queue__c>{ chainStep });

        Sharing_Queue__c row = [
            SELECT Job__c, Status__c, Next_Queue__c
            FROM Sharing_Queue__c
            WHERE Id = :chainStep.Id
        ];
        System.assertEquals(fanout.Id, row.Job__c);
        System.assertEquals(SharingQueueService.STATUS_BLOCKED, row.Status__c);
        System.assertEquals(null, row.Next_Queue__c);
        System.assertEquals(1, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies row with job already set is not treated as event.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRowWithJobAlreadySetIsNotTreatedAsEvent() {
        reset();
        Job__c job = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            JobCatalogService.APP_APPLICATION1);
        Sharing_Queue__c row = eventRow(JobCatalogService.EVENT_TEAM_MEMBER_CREATED);
        row.Job__c = job.Id;
        insert row;
        expand(new List<Sharing_Queue__c>{ row });

        Sharing_Queue__c saved = [
            SELECT Job__c, Next_Queue__c, Status__c
            FROM Sharing_Queue__c
            WHERE Id = :row.Id
        ];
        System.assertEquals(job.Id, saved.Job__c);
        System.assertEquals(null, saved.Next_Queue__c);
        System.assertEquals(1, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies missing trigger event mapping fails the event row.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMissingTriggerEventMappingFailsTheEventRow() {
        reset();
        Job_Trigger_Event__c mapping = [
            SELECT Id, Is_Active__c
            FROM Job_Trigger_Event__c
            WHERE Event_Key__c = :JobCatalogService.EVENT_MANUAL
            LIMIT 1
        ];
        mapping.Is_Active__c = false;
        update mapping;
        JobCatalogService.resetCache();

        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_MANUAL);
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c failed = [
            SELECT Status__c, Job__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_FAILED, failed.Status__c);
        System.assertEquals(null, failed.Job__c);
        System.assert(
            failed.Last_Error__c != null
                && failed.Last_Error__c.contains(JobCatalogService.EVENT_MANUAL),
            'Last error should name the unmapped trigger event');
        System.assertEquals(1, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies inactive job on mapping explains miss.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testInactiveJobOnMappingExplainsMiss() {
        reset();
        Job_Trigger_Event__c mapping = [
            SELECT Id, Job__c
            FROM Job_Trigger_Event__c
            WHERE Event_Key__c = :JobCatalogService.EVENT_MANUAL
            LIMIT 1
        ];
        update new Job__c(Id = mapping.Job__c, Is_Active__c = false);
        JobCatalogService.resetCache();

        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_MANUAL);
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c failed = [
            SELECT Status__c, Job__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_FAILED, failed.Status__c);
        System.assertEquals(null, failed.Job__c);
        System.assert(
            failed.Last_Error__c != null && failed.Last_Error__c.contains('inactive Job'),
            failed.Last_Error__c);
    }

    /**
     * @description Verifies expand matches trigger event when event key differs.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testExpandMatchesTriggerEventWhenEventKeyDiffers() {
        reset();
        Job_Trigger_Event__c mapping = [
            SELECT Id, Event_Key__c, Trigger_Event__c
            FROM Job_Trigger_Event__c
            WHERE Trigger_Event__c = :JobCatalogService.EVENT_RELATED_RECORD_CREATED
            LIMIT 1
        ];
        mapping.Event_Key__c = 'OCC.RelatedRecordCreated';
        update mapping;
        JobCatalogService.resetCache();

        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_RELATED_RECORD_CREATED);
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c row = [
            SELECT Status__c, Job__r.Handler__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, row.Status__c, row.Last_Error__c);
        System.assertEquals(
            JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            row.Job__r.Handler__c);
    }

    /**
     * @description Verifies expand matches event key when trigger event differs.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testExpandMatchesEventKeyWhenTriggerEventDiffers() {
        reset();
        Job_Trigger_Event__c manualMapping = [
            SELECT Id, Event_Key__c, Is_Active__c
            FROM Job_Trigger_Event__c
            WHERE Event_Key__c = :JobCatalogService.EVENT_MANUAL
            LIMIT 1
        ];
        manualMapping.Event_Key__c = 'Manual.inactive';
        manualMapping.Is_Active__c = false;
        update manualMapping;

        Job_Trigger_Event__c updatedMapping = [
            SELECT Id, Event_Key__c, Trigger_Event__c, Job__c
            FROM Job_Trigger_Event__c
            WHERE Trigger_Event__c = :JobCatalogService.EVENT_TEAM_MEMBER_UPDATED
            LIMIT 1
        ];
        updatedMapping.Event_Key__c = JobCatalogService.EVENT_MANUAL;
        update updatedMapping;
        JobCatalogService.resetCache();

        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_MANUAL);
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c row = [
            SELECT Status__c, Job__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, row.Status__c, row.Last_Error__c);
        System.assertEquals(updatedMapping.Job__c, row.Job__c);
    }

    /**
     * @description Verifies expand resolves mapped job when handler is shared.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testExpandResolvesMappedJobWhenHandlerIsShared() {
        reset();
        Job__c seedJob = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            JobCatalogService.APP_APPLICATION1);
        Job__c laterJob = new Job__c(
            Name = 'OCC Share Matter',
            Handler__c = JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            Processor__c = JobCatalogService.PROCESSOR_QUEUEABLE,
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        insert laterJob;

        Job_Trigger_Event__c mapping = [
            SELECT Id, Job__c
            FROM Job_Trigger_Event__c
            WHERE Event_Key__c = :JobCatalogService.EVENT_MANUAL
            LIMIT 1
        ];
        mapping.Job__c = seedJob.Id;
        update mapping;
        JobCatalogService.resetCache();

        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_MANUAL);
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c row = [
            SELECT Status__c, Job__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, row.Status__c, row.Last_Error__c);
        System.assertEquals(seedJob.Id, row.Job__c);
    }

    /**
     * @description Verifies mixed insert expands only event rows.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMixedInsertExpandsOnlyEventRows() {
        reset();
        Job__c job = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            JobCatalogService.APP_APPLICATION1);
        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_RELATED_RECORD_CREATED);
        Sharing_Queue__c alreadyMapped = eventRow(JobCatalogService.EVENT_MANUAL);
        alreadyMapped.Job__c = job.Id;
        insert new List<Sharing_Queue__c>{ event, alreadyMapped };
        expand(new List<Sharing_Queue__c>{ event, alreadyMapped });

        Sharing_Queue__c expanded = [
            SELECT Job__r.Handler__c, Status__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(
            JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            expanded.Job__r.Handler__c);
        System.assertEquals(SharingQueueService.STATUS_PENDING, expanded.Status__c);

        Sharing_Queue__c untouched = [
            SELECT Job__c, Next_Queue__c
            FROM Sharing_Queue__c
            WHERE Id = :alreadyMapped.Id
        ];
        System.assertEquals(job.Id, untouched.Job__c);
        System.assertEquals(null, untouched.Next_Queue__c);
    }

    /**
     * @description Verifies failed to pending kicks queueable without stacking.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testFailedToPendingKicksQueueableWithoutStacking() {
        reset();
        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_RELATED_RECORD_CREATED);
        insert event;

        Sharing_Queue__c failed = new Sharing_Queue__c(
            Id = event.Id,
            Status__c = SharingQueueService.STATUS_FAILED,
            Last_Error__c = 'test seed',
            Retry_Count__c = 0
        );
        update failed;
        SharingQueueQueueable.resetEnqueueGuard();

        Test.startTest();
        update new Sharing_Queue__c(
            Id = event.Id,
            Status__c = SharingQueueService.STATUS_PENDING
        );
        Test.stopTest();

        Sharing_Queue__c row = [
            SELECT Status__c, Retry_Count__c, Last_Error__c, Job__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertNotEquals(null, row.Job__c);
        System.assertNotEquals(
            SharingQueueService.STATUS_PROCESSING,
            row.Status__c,
            row.Last_Error__c);
        System.assert(
            row.Status__c == SharingQueueService.STATUS_COMPLETED
                || row.Status__c == SharingQueueService.STATUS_PENDING
                || row.Status__c == SharingQueueService.STATUS_FAILED,
            'Worker should leave the row Completed, Pending (retry), or Failed: '
                + row.Status__c + ' ' + row.Last_Error__c);
    }

    /**
     * @description Verifies wrong application does not use OCC mapping.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testWrongApplicationDoesNotUseOccMapping() {
        reset();
        Sharing_Queue__c event = eventRow(JobCatalogService.EVENT_TEAM_MEMBER_CREATED);
        event.Application__c = 'GLS';
        insert event;
        expand(new List<Sharing_Queue__c>{ event });

        Sharing_Queue__c failed = [
            SELECT Status__c, Job__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id = :event.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_FAILED, failed.Status__c);
        System.assertEquals(null, failed.Job__c);
        System.assert(
            failed.Last_Error__c != null && failed.Last_Error__c.contains('GLS'),
            failed.Last_Error__c);
    }

    /**
     * @description Verifies head job for requires matching application.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testHeadJobForRequiresMatchingApplication() {
        reset();
        System.assertEquals(
            null,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_TEAM_MEMBER_CREATED, 'GLS'));
        System.assertNotEquals(
            null,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
                JobCatalogService.APP_APPLICATION1));
    }
}
