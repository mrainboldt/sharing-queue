/**
 * @description SharingQueueInvocable replaces Flow Create Records on Sharing_Queue__c.
 * @author Melissa Rainboldt
 */
@IsTest
private class SharingQueueInvocableTest {

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
        SharingQueueQueueable.resetEnqueueGuard();
        SharingQueueSettings.resetCache();
    }

    /**
     * @description Builds an invocable request for a created team member.
     * @author Melissa Rainboldt
     * @param sourceId Source record Id, such as a team member or child.
     * @return The SharingQueueInvocable.Request produced for this test.
     */
    private static SharingQueueInvocable.Request tmCreated(Id sourceId) {
        SharingQueueInvocable.Request request = new SharingQueueInvocable.Request();
        request.application = SharingQueueInvocable.Application.OCC;
        request.triggerEvent = SharingQueueInvocable.TriggerEvent.TeamMemberCreated;
        request.mainRecordId = UserInfo.getUserId();
        request.sourceRecordId = sourceId;
        return request;
    }

    /**
     * @description Verifies enqueue expands catalog chain.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testEnqueueExpandsCatalogChain() {
        reset();
        SharingQueueInvocable.Request request = tmCreated(UserInfo.getUserId());

        List<SharingQueueInvocable.Result> results =
            SharingQueueInvocable.enqueue(new List<SharingQueueInvocable.Request>{ request });

        System.assertEquals(1, results.size());
        System.assertEquals(1, results[0].recordsEnqueued);
        Sharing_Queue__c head = [
            SELECT Job__c, Job__r.Handler__c, Status__c, Next_Queue__c, Payload__c,
                   Is_Chain_Step__c, Application__c, Main_Record_Id__c,
                   Source_Record_Id__c, Source_Object_Api_Name__c, Main_Object_Api_Name__c
            FROM Sharing_Queue__c
            WHERE Is_Chain_Step__c = false
            LIMIT 1
        ];
        System.assertEquals(JobCatalogService.APP_APPLICATION1, head.Application__c);
        System.assertEquals(String.valueOf(UserInfo.getUserId()), head.Main_Record_Id__c);
        System.assertEquals(String.valueOf(UserInfo.getUserId()), head.Source_Record_Id__c);
        System.assertEquals('User', head.Main_Object_Api_Name__c);
        System.assertEquals('User', head.Source_Object_Api_Name__c);
        System.assertEquals(
            JobCatalogService.HANDLER_SHARE_MAIN_DIRECT, head.Job__r.Handler__c);
        System.assertNotEquals(null, head.Next_Queue__c);
        SharingQueueService.Payload payload =
            SharingQueueService.parsePayload(head.Payload__c);
        System.assertEquals(null, payload.userOrGroupId);
        System.assertEquals(null, payload.accessLevel);
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Sharing_Queue__c
                WHERE Is_Chain_Step__c = true
                AND Status__c = :SharingQueueService.STATUS_BLOCKED
            ]);
    }

    /**
     * @description Verifies does not enqueue when disabled.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testDoesNotEnqueueWhenDisabled() {
        reset();
        SharingQueueSettings.useSharingQueueOverride = false;
        SharingQueueInvocable.Request request = tmCreated(UserInfo.getUserId());

        List<SharingQueueInvocable.Result> results =
            SharingQueueInvocable.enqueue(new List<SharingQueueInvocable.Request>{ request });

        System.assertEquals(1, results.size());
        System.assertEquals(0, results[0].recordsEnqueued);
        System.assertEquals(0, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies related and reconcile events.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedAndReconcileEvents() {
        reset();
        Account child = new Account(Name = 'Invocable related');
        insert child;
        SharingQueueInvocable.Request related = new SharingQueueInvocable.Request();
        related.application = SharingQueueInvocable.Application.OCC;
        related.triggerEvent = SharingQueueInvocable.TriggerEvent.RelatedRecordCreated;
        related.mainRecordId = UserInfo.getUserId();
        related.sourceRecordId = child.Id;

        SharingQueueInvocable.Request reconcile = new SharingQueueInvocable.Request();
        reconcile.application = SharingQueueInvocable.Application.OCC;
        reconcile.triggerEvent = SharingQueueInvocable.TriggerEvent.ReconcileSweep;
        reconcile.mainRecordId = UserInfo.getUserId();

        List<SharingQueueInvocable.Result> results = SharingQueueInvocable.enqueue(
            new List<SharingQueueInvocable.Request>{ related, reconcile });

        System.assertEquals(1, results[0].recordsEnqueued);
        System.assertEquals(1, results[1].recordsEnqueued);
        Sharing_Queue__c relatedRow = [
            SELECT Source_Object_Api_Name__c
            FROM Sharing_Queue__c
            WHERE Trigger_Event__c = :JobCatalogService.EVENT_RELATED_RECORD_CREATED
            AND Is_Chain_Step__c = false
            LIMIT 1
        ];
        System.assertEquals('Account', relatedRow.Source_Object_Api_Name__c);
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Sharing_Queue__c
                WHERE Trigger_Event__c = :JobCatalogService.EVENT_RECONCILE_SWEEP
                AND Is_Chain_Step__c = false
            ]);
    }

    /**
     * @description Verifies skips incomplete requests.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testSkipsIncompleteRequests() {
        reset();
        SharingQueueInvocable.Request blank = new SharingQueueInvocable.Request();
        List<SharingQueueInvocable.Result> results =
            SharingQueueInvocable.enqueue(new List<SharingQueueInvocable.Request>{ blank });
        System.assertEquals(1, results.size());
        System.assertEquals(0, results[0].recordsEnqueued);
        System.assertEquals(0, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies OCC trigger event is passed through.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testOccTriggerEventIsPassedThrough() {
        reset();
        SharingQueueInvocable.Request request = tmCreated(UserInfo.getUserId());
        request.triggerEvent = SharingQueueInvocable.TriggerEvent.OCC_Legal_Team_Member_Created;

        List<SharingQueueInvocable.Result> results =
            SharingQueueInvocable.enqueue(new List<SharingQueueInvocable.Request>{ request });

        System.assertEquals(1, results[0].recordsEnqueued);
        Sharing_Queue__c row = [
            SELECT Trigger_Event__c, Job__r.Handler__c, Status__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Is_Chain_Step__c = false
            LIMIT 1
        ];
        System.assertEquals(JobCatalogService.EVENT_OCC_LTM_CREATED, row.Trigger_Event__c);
        System.assertEquals(
            SharingQueueService.STATUS_PENDING,
            row.Status__c,
            row.Last_Error__c);
        System.assertEquals(JobCatalogService.HANDLER_SHARE_MAIN_DIRECT, row.Job__r.Handler__c);
    }

    /**
     * @description Verifies OCC deleted expands to reconcile main.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testOccDeletedExpandsToReconcileMain() {
        reset();
        SharingQueueInvocable.Request request = tmCreated(UserInfo.getUserId());
        request.triggerEvent = SharingQueueInvocable.TriggerEvent.OCC_Legal_Team_Member_Deleted;

        List<SharingQueueInvocable.Result> results =
            SharingQueueInvocable.enqueue(new List<SharingQueueInvocable.Request>{ request });

        System.assertEquals(1, results[0].recordsEnqueued);
        Sharing_Queue__c row = [
            SELECT Trigger_Event__c, Job__r.Handler__c, Job__r.Processor__c,
                   Job__r.Next_Job__c, Status__c, Last_Error__c, Next_Queue__c
            FROM Sharing_Queue__c
            WHERE Is_Chain_Step__c = false
            LIMIT 1
        ];
        System.assertEquals(JobCatalogService.EVENT_OCC_LTM_DELETED, row.Trigger_Event__c);
        System.assertEquals(
            SharingQueueService.STATUS_PENDING,
            row.Status__c,
            row.Last_Error__c);
        System.assertEquals(JobCatalogService.HANDLER_RECONCILE_MAIN, row.Job__r.Handler__c);
        System.assertEquals(JobCatalogService.PROCESSOR_BATCH, row.Job__r.Processor__c);
        System.assertEquals(null, row.Job__r.Next_Job__c);
        System.assertEquals(null, row.Next_Queue__c);
    }

    /**
     * @description Verifies OCC end expands to reconcile main.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testOccEndExpandsToReconcileMain() {
        reset();
        SharingQueueInvocable.Request request = tmCreated(UserInfo.getUserId());
        request.triggerEvent = SharingQueueInvocable.TriggerEvent.OCC_Legal_Team_Member_End;

        SharingQueueInvocable.enqueue(new List<SharingQueueInvocable.Request>{ request });

        Sharing_Queue__c row = [
            SELECT Job__r.Handler__c, Status__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Trigger_Event__c = :JobCatalogService.EVENT_OCC_LTM_END
            AND Is_Chain_Step__c = false
            LIMIT 1
        ];
        System.assertEquals(
            SharingQueueService.STATUS_PENDING,
            row.Status__c,
            row.Last_Error__c);
        System.assertEquals(JobCatalogService.HANDLER_RECONCILE_MAIN, row.Job__r.Handler__c);
    }

    /**
     * @description Verifies enum API names match queue picklists.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testEnumApiNamesMatchQueuePicklists() {
        System.assertEquals(
            'OCC',
            SharingQueueInvocable.applicationApiName(SharingQueueInvocable.Application.OCC));
        System.assertEquals(
            'GLS',
            SharingQueueInvocable.applicationApiName(SharingQueueInvocable.Application.GLS));
        System.assertEquals(
            JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            SharingQueueInvocable.triggerEventApiName(
                SharingQueueInvocable.TriggerEvent.TeamMemberCreated));
        System.assertEquals(
            JobCatalogService.EVENT_OCC_LTM_CREATED,
            SharingQueueInvocable.triggerEventApiName(
                SharingQueueInvocable.TriggerEvent.OCC_Legal_Team_Member_Created));
        System.assertEquals(
            'OCC.MatterRelatedRecord.Create',
            SharingQueueInvocable.triggerEventApiName(
                SharingQueueInvocable.TriggerEvent.OCC_MatterRelatedRecord_Create));
    }
}
