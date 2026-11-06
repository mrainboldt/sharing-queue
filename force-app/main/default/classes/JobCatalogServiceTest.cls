/**
 * @description Seeded catalog: ReconcileMain is Batch with no Next Job.
 * Generic Deleted/Sweep/Manual and Deleted/End map to that Job.
 * @author Melissa Rainboldt
 */
@IsTest
private class JobCatalogServiceTest {

    /**
     * @description Inserts records shared by the tests in this class.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestSetup
    static void makeData() {
        JobCatalogService.seedCatalog();
    }

    /**
     * @description Verifies reconcile main job is batch terminal .
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testReconcileMainJobIsBatchTerminalOcc() {
        JobCatalogService.resetCache();
        Job__c job = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_RECONCILE_MAIN,
            JobCatalogService.APP_APPLICATION1);
        System.assertNotEquals(null, job);
        System.assertEquals(JobCatalogService.HANDLER_RECONCILE_MAIN, job.Handler__c);
        System.assertEquals(JobCatalogService.PROCESSOR_BATCH, job.Processor__c);
        System.assertEquals(null, job.Next_Job__c);
        System.assertEquals(true, job.Is_Active__c);
    }

    /**
     * @description Verifies generic events map to reconcile main.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testGenericEventsMapToReconcileMain() {
        JobCatalogService.resetCache();
        Id reconcileId = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_RECONCILE_MAIN,
            JobCatalogService.APP_APPLICATION1).Id;
        System.assertEquals(
            reconcileId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_TEAM_MEMBER_DELETED,
                JobCatalogService.APP_APPLICATION1).Id);
        System.assertEquals(
            reconcileId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_RECONCILE_SWEEP,
                JobCatalogService.APP_APPLICATION1).Id);
        System.assertEquals(
            reconcileId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_MANUAL,
                JobCatalogService.APP_APPLICATION1).Id);
        System.assertEquals(
            1,
            JobCatalogService.walkChain(
                JobCatalogService.headJobFor(
                    JobCatalogService.EVENT_RECONCILE_SWEEP,
                    JobCatalogService.APP_APPLICATION1)).size());
    }

    /**
     * @description Verifies OCC deleted and end map to reconcile main.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testOccDeletedAndEndMapToReconcileMain() {
        JobCatalogService.resetCache();
        Id reconcileId = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_RECONCILE_MAIN,
            JobCatalogService.APP_APPLICATION1).Id;
        System.assertEquals(
            reconcileId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_OCC_LTM_DELETED,
                JobCatalogService.APP_APPLICATION1).Id);
        System.assertEquals(
            reconcileId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_OCC_LTM_END,
                JobCatalogService.APP_APPLICATION1).Id);
        Job_Trigger_Event__c deleted = [
            SELECT Trigger_Event__c, Application__c, Job__c, Is_Active__c
            FROM Job_Trigger_Event__c
            WHERE Event_Key__c = :JobCatalogService.EVENT_OCC_LTM_DELETED
            LIMIT 1
        ];
        System.assertEquals(JobCatalogService.EVENT_TEAM_MEMBER_DELETED, deleted.Trigger_Event__c);
        System.assertEquals(JobCatalogService.APP_APPLICATION1, deleted.Application__c);
        System.assertEquals(reconcileId, deleted.Job__c);
        System.assertEquals(true, deleted.Is_Active__c);
    }

    /**
     * @description Verifies OCC created and start map to share main direct.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testOccCreatedAndStartMapToShareMainDirect() {
        JobCatalogService.resetCache();
        Id shareMainId = JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_SHARE_MAIN_DIRECT,
            JobCatalogService.APP_APPLICATION1).Id;
        System.assertEquals(
            shareMainId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_OCC_LTM_CREATED,
                JobCatalogService.APP_APPLICATION1).Id);
        System.assertEquals(
            shareMainId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_OCC_LTM_START,
                JobCatalogService.APP_APPLICATION1).Id);
        System.assertEquals(
            shareMainId,
            JobCatalogService.headJobFor(
                JobCatalogService.EVENT_OCC_LTM_UPDATED,
                JobCatalogService.APP_APPLICATION1).Id);
    }
}
