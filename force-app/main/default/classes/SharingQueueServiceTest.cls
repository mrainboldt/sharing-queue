/**
 * @description Compaction thresholds come from Sharing_Queue_Setting__mdt (test overlays).
 * compactOpenWork promotes related/fan-out piles on one Main to ReconcileMain.
 * @author Melissa Rainboldt
 */
@IsTest
private class SharingQueueServiceTest {

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
        SharingQueueSettings.resetCache();
        SharingQueueService.activeQueueableOverride = null;
        SharingQueueService.activeBatchOverride = null;
        SharingQueueService.resetCompactGuard();
        SharingQueueQueueable.resetEnqueueGuard();
    }

    /**
     * @description Builds a fake main record Id.
     * @author Melissa Rainboldt
     * @return The text produced for this test.
     */
    private static String mainId() {
        return String.valueOf(UserInfo.getUserId());
    }

    /**
     * @description Builds a fake source record Id for the sequence number.
     * @author Melissa Rainboldt
     * @param n Sequence number used to build unique test data.
     * @return The text produced for this test.
     */
    private static String sourceId(Integer n) {
        return '0010000000000' + String.valueOf(100 + n);
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
     * @description Returns the reconcile Job used by the test.
     * @author Melissa Rainboldt
     * @return The Job__c produced for this test.
     */
    private static Job__c reconcileJob() {
        return JobCatalogService.jobByHandler(
            JobCatalogService.HANDLER_RECONCILE_MAIN,
            JobCatalogService.APP_APPLICATION1);
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
     * @description Builds a pending Sharing Queue row.
     * @author Melissa Rainboldt
     * @param triggerEvent Trigger event key used to resolve the head Job.
     * @param jobId Job Id.
     * @param sourceId Source record Id, such as a team member or child.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c pendingRow(String triggerEvent, Id jobId, String sourceId) {
        return pendingRow(triggerEvent, jobId, sourceId, JobCatalogService.APP_APPLICATION1);
    }

    /**
     * @description Builds a pending Sharing Queue row.
     * @author Melissa Rainboldt
     * @param triggerEvent Trigger event key used to resolve the head Job.
     * @param jobId Job Id.
     * @param sourceId Source record Id, such as a team member or child.
     * @param application Application API name that selects the catalog and sharing configuration.
     * @return The Sharing_Queue__c produced for this test.
     */
    private static Sharing_Queue__c pendingRow(
            String triggerEvent,
            Id jobId,
            String sourceId,
            String application) {
        return new Sharing_Queue__c(
            Trigger_Event__c          = triggerEvent,
            Main_Record_Id__c         = mainId(),
            Main_Object_Api_Name__c   = 'User',
            Source_Record_Id__c       = sourceId,
            Source_Object_Api_Name__c = 'User',
            Application__c            = application,
            Status__c                 = SharingQueueService.STATUS_PENDING,
            Is_Chain_Step__c          = false,
            Retry_Count__c            = 0,
            Job__c                    = jobId
        );
    }

    /**
     * @description Inserts pending related-record queue rows.
     * @author Melissa Rainboldt
     * @param count How many rows to create.
     * @return The collection produced for this test.
     */
    private static List<Sharing_Queue__c> insertRelated(Integer count) {
        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        Id jobId = relatedJob().Id;
        for (Integer i = 0; i < count; i++) {
            rows.add(pendingRow(
                JobCatalogService.EVENT_RELATED_RECORD_CREATED,
                jobId,
                sourceId(i)));
        }
        insert rows;
        return rows;
    }

    /**
     * @description Inserts pending fan-out queue rows.
     * @author Melissa Rainboldt
     * @param count How many rows to create.
     * @return The collection produced for this test.
     */
    private static List<Sharing_Queue__c> insertFanout(Integer count) {
        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        Id jobId = fanoutJob().Id;
        for (Integer i = 0; i < count; i++) {
            rows.add(pendingRow(
                JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
                jobId,
                sourceId(50 + i)));
        }
        insert rows;
        return rows;
    }

    /**
     * @description Counts reconcile queue rows.
     * @author Melissa Rainboldt
     * @return The count produced for this test.
     */
    private static Integer reconcileCount() {
        List<String> openStatuses = new List<String>{
            SharingQueueService.STATUS_PENDING,
            SharingQueueService.STATUS_BLOCKED
        };
        return [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Job__r.Handler__c = :JobCatalogService.HANDLER_RECONCILE_MAIN
            AND Status__c IN :openStatuses
        ];
    }

    /**
     * @description Verifies settings defaults and overlay.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testSettingsDefaultsAndOverlay() {
        reset();
        System.assertEquals(
            SharingQueueSettings.DEFAULT_RELATED_BUNCH,
            SharingQueueSettings.relatedBunchThreshold());
        System.assertEquals(
            SharingQueueSettings.DEFAULT_FANOUT_SOME,
            SharingQueueSettings.fanoutSomeThreshold());
        System.assertEquals(
            SharingQueueSettings.DEFAULT_MIXED_PRODUCT,
            SharingQueueSettings.mixedProductThreshold());
        System.assertEquals(
            SharingQueueSettings.DEFAULT_OPEN_WORK,
            SharingQueueSettings.openWorkThreshold());

        SharingQueueSettings.openWorkOverride = 2;
        System.assertEquals(2, SharingQueueSettings.openWorkThreshold());
        System.assertEquals(
            SharingQueueSettings.DEFAULT_RELATED_BUNCH,
            SharingQueueSettings.relatedBunchThreshold());

        System.assertEquals(true, SharingQueueSettings.useSharingQueue());
        SharingQueueSettings.useSharingQueueOverride = false;
        System.assertEquals(false, SharingQueueSettings.useSharingQueue());
    }

    /**
     * @description Verifies enqueue no-ops when sharing queue disabled.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testEnqueueNoOpsWhenSharingQueueDisabled() {
        reset();
        SharingQueueSettings.useSharingQueueOverride = false;
        Integer inserted = SharingQueueService.enqueueReconcileForMains(
            new Set<Id>{ UserInfo.getUserId() },
            JobCatalogService.EVENT_RECONCILE_SWEEP,
            JobCatalogService.APP_APPLICATION1);
        System.assertEquals(0, inserted);
        System.assertEquals(0, [SELECT COUNT() FROM Sharing_Queue__c]);
    }

    /**
     * @description Verifies should promote open work does not require mix.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testShouldPromoteOpenWorkDoesNotRequireMix() {
        reset();
        SharingQueueSettings.openWorkOverride = 2;
        System.assertEquals(true, SharingQueueService.shouldPromoteToReconcile(2, 0));
        System.assertEquals(true, SharingQueueService.shouldPromoteToReconcile(0, 2));
        System.assertEquals(false, SharingQueueService.shouldPromoteToReconcile(1, 0));
        System.assertEquals(false, SharingQueueService.shouldPromoteToReconcile(null, 2));
    }

    /**
     * @description Verifies should promote mixed thresholds.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testShouldPromoteMixedThresholds() {
        reset();
        SharingQueueSettings.openWorkOverride = 100;
        SharingQueueSettings.relatedBunchOverride = 10;
        SharingQueueSettings.fanoutSomeOverride = 3;
        SharingQueueSettings.mixedProductOverride = 15;

        System.assertEquals(false, SharingQueueService.shouldPromoteToReconcile(1, 1));
        System.assertEquals(true, SharingQueueService.shouldPromoteToReconcile(10, 1));
        System.assertEquals(true, SharingQueueService.shouldPromoteToReconcile(1, 3));
        System.assertEquals(true, SharingQueueService.shouldPromoteToReconcile(5, 3));
        System.assertEquals(false, SharingQueueService.shouldPromoteToReconcile(4, 2));
    }

    /**
     * @description Verifies zero threshold disables rule.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testZeroThresholdDisablesRule() {
        reset();
        SharingQueueSettings.openWorkOverride = 0;
        SharingQueueSettings.relatedBunchOverride = 0;
        SharingQueueSettings.fanoutSomeOverride = 0;
        SharingQueueSettings.mixedProductOverride = 0;
        System.assertEquals(false, SharingQueueService.shouldPromoteToReconcile(50, 50));

        SharingQueueSettings.relatedBunchOverride = 2;
        System.assertEquals(true, SharingQueueService.shouldPromoteToReconcile(2, 1));
        System.assertEquals(false, SharingQueueService.shouldPromoteToReconcile(2, 0));
    }

    /**
     * @description Verifies related only below open work stays pending.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedOnlyBelowOpenWorkStaysPending() {
        reset();
        SharingQueueSettings.openWorkOverride = 20;
        List<Sharing_Queue__c> related = insertRelated(2);

        Integer decisions = SharingQueueService.compactOpenWork();

        System.assertEquals(0, decisions);
        System.assertEquals(0, reconcileCount());
        for (Sharing_Queue__c row : [
            SELECT Status__c FROM Sharing_Queue__c WHERE Id IN :related
        ]) {
            System.assertEquals(SharingQueueService.STATUS_PENDING, row.Status__c);
        }
    }

    /**
     * @description Verifies related only at open work promotes to reconcile.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedOnlyAtOpenWorkPromotesToReconcile() {
        reset();
        SharingQueueSettings.openWorkOverride = 2;
        List<Sharing_Queue__c> related = insertRelated(2);
        Sharing_Queue__c mainShare = pendingRow(
            JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            mainDirectJob().Id,
            sourceId(99));
        insert mainShare;

        Integer decisions = SharingQueueService.compactOpenWork();

        System.assertEquals(1, decisions);
        System.assertEquals(1, reconcileCount());
        for (Sharing_Queue__c row : [
            SELECT Status__c, Last_Error__c FROM Sharing_Queue__c WHERE Id IN :related
        ]) {
            System.assertEquals(SharingQueueService.STATUS_CANCELLED, row.Status__c);
            System.assert(
                row.Last_Error__c != null
                    && row.Last_Error__c.contains('Subsumed by a broader job'),
                row.Last_Error__c);
        }
        Sharing_Queue__c leftover = [
            SELECT Status__c FROM Sharing_Queue__c WHERE Id = :mainShare.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, leftover.Status__c);
    }

    /**
     * @description Verifies mixed below thresholds does not promote.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMixedBelowThresholdsDoesNotPromote() {
        reset();
        SharingQueueSettings.openWorkOverride = 20;
        SharingQueueSettings.relatedBunchOverride = 10;
        SharingQueueSettings.fanoutSomeOverride = 3;
        SharingQueueSettings.mixedProductOverride = 15;
        insertRelated(1);
        insertFanout(1);

        Integer decisions = SharingQueueService.compactOpenWork();

        System.assertEquals(0, decisions);
        System.assertEquals(0, reconcileCount());
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Status__c = :SharingQueueService.STATUS_PENDING
        ]);
    }

    /**
     * @description Verifies mixed related bunch promotes.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMixedRelatedBunchPromotes() {
        reset();
        SharingQueueSettings.openWorkOverride = 100;
        SharingQueueSettings.relatedBunchOverride = 2;
        SharingQueueSettings.fanoutSomeOverride = 10;
        SharingQueueSettings.mixedProductOverride = 100;
        List<Sharing_Queue__c> related = insertRelated(2);
        List<Sharing_Queue__c> fanout = insertFanout(1);

        Integer decisions = SharingQueueService.compactOpenWork();

        System.assertEquals(1, decisions);
        System.assertEquals(1, reconcileCount());
        System.assertEquals(3, [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE (Id IN :related OR Id IN :fanout)
            AND Status__c = :SharingQueueService.STATUS_CANCELLED
        ]);
    }

    /**
     * @description Verifies mixed fanout some promotes.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMixedFanoutSomePromotes() {
        reset();
        SharingQueueSettings.openWorkOverride = 100;
        SharingQueueSettings.relatedBunchOverride = 10;
        SharingQueueSettings.fanoutSomeOverride = 2;
        SharingQueueSettings.mixedProductOverride = 100;
        insertRelated(1);
        insertFanout(2);

        System.assertEquals(1, SharingQueueService.compactOpenWork());
        System.assertEquals(1, reconcileCount());
    }

    /**
     * @description Verifies mixed product promotes.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMixedProductPromotes() {
        reset();
        SharingQueueSettings.openWorkOverride = 100;
        SharingQueueSettings.relatedBunchOverride = 10;
        SharingQueueSettings.fanoutSomeOverride = 10;
        SharingQueueSettings.mixedProductOverride = 6;
        insertRelated(2);
        insertFanout(3);

        System.assertEquals(1, SharingQueueService.compactOpenWork());
        System.assertEquals(1, reconcileCount());
    }

    /**
     * @description Verifies open reconcile cancels related and fanout.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testOpenReconcileCancelsRelatedAndFanout() {
        reset();
        SharingQueueSettings.openWorkOverride = 100;
        insertRelated(1);
        insertFanout(1);
        Sharing_Queue__c reconcile = pendingRow(
            JobCatalogService.EVENT_RECONCILE_SWEEP,
            reconcileJob().Id,
            null);
        insert reconcile;

        Integer decisions = SharingQueueService.compactOpenWork();

        System.assertEquals(1, decisions);
        Sharing_Queue__c stillOpen = [
            SELECT Status__c FROM Sharing_Queue__c WHERE Id = :reconcile.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, stillOpen.Status__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Job__r.Handler__c = :JobCatalogService.HANDLER_RECONCILE_MAIN
        ]);
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Status__c = :SharingQueueService.STATUS_CANCELLED
        ]);
    }

    /**
     * @description Verifies compact does not mix applications.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testCompactDoesNotMixApplications() {
        reset();
        SharingQueueSettings.openWorkOverride = 2;
        insertRelated(2);
        Job__c glsRelated = new Job__c(
            Name = 'GLS ShareRelated',
            Handler__c = JobCatalogService.HANDLER_SHARE_RELATED_TO_ALL_TEAM_MEMBERS,
            Processor__c = JobCatalogService.PROCESSOR_QUEUEABLE,
            Is_Active__c = true,
            Application__c = 'GLS'
        );
        insert glsRelated;
        Sharing_Queue__c glsRow = pendingRow(
            JobCatalogService.EVENT_RELATED_RECORD_CREATED,
            glsRelated.Id,
            sourceId(200),
            'GLS');
        insert glsRow;

        Integer decisions = SharingQueueService.compactOpenWork();

        System.assertEquals(1, decisions);
        List<String> openStatuses = new List<String>{
            SharingQueueService.STATUS_PENDING,
            SharingQueueService.STATUS_BLOCKED
        };
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Job__r.Handler__c = :JobCatalogService.HANDLER_RECONCILE_MAIN
            AND Application__c = :JobCatalogService.APP_APPLICATION1
            AND Status__c IN :openStatuses
        ]);
        Sharing_Queue__c leftover = [
            SELECT Status__c, Application__c FROM Sharing_Queue__c WHERE Id = :glsRow.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_PENDING, leftover.Status__c);
        System.assertEquals('GLS', leftover.Application__c);
    }

    /**
     * @description Verifies reconcile enqueue does not coalesce across applications.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testReconcileEnqueueDoesNotCoalesceAcrossApplications() {
        reset();
        Sharing_Queue__c glsOpen = pendingRow(
            JobCatalogService.EVENT_RECONCILE_SWEEP,
            null,
            null,
            'GLS');
        glsOpen.Is_Chain_Step__c = true;
        insert glsOpen;

        Integer inserted = SharingQueueService.enqueueReconcileForMains(
            new Set<Id>{ UserInfo.getUserId() },
            JobCatalogService.EVENT_RECONCILE_SWEEP,
            JobCatalogService.APP_APPLICATION1);

        System.assertEquals(1, inserted);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Application__c = :JobCatalogService.APP_APPLICATION1
            AND Trigger_Event__c = :JobCatalogService.EVENT_RECONCILE_SWEEP
        ]);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Application__c = 'GLS'
            AND Trigger_Event__c = :JobCatalogService.EVENT_RECONCILE_SWEEP
        ]);
    }

    /**
     * @description Verifies share DML exception marks queue failed after max retries.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testShareDmlExceptionMarksQueueFailedAfterMaxRetries() {
        reset();
        Sharing_Queue__c row = pendingRow(
            JobCatalogService.EVENT_RELATED_RECORD_CREATED,
            relatedJob().Id,
            sourceId(1));
        insert row;

        SharingConfigService.SharingException shareEx;
        try {
            TeamMemberSharingService.throwIfShareDmlFailed(
                'insert',
                new List<String>{ 'FIELD_INTEGRITY_EXCEPTION: invalid access level' });
            System.assert(false, 'expected share DML throw');
        } catch (SharingConfigService.SharingException e) {
            shareEx = e;
        }

        for (Integer i = 0; i < SharingQueueService.MAX_RETRIES; i++) {
            List<Sharing_Queue__c> toClaim = [
                SELECT Id
                     , Trigger_Event__c
                     , Job__c
                     , Job__r.Handler__c
                     , Job__r.Processor__c
                     , Job__r.Name
                     , Main_Record_Id__c
                     , Main_Object_Api_Name__c
                     , Source_Record_Id__c
                     , Source_Object_Api_Name__c
                     , Status__c
                     , Next_Queue__c
                     , Retry_Count__c
                     , Payload__c
                     , Records_Processed__c
                     , Application__c
                FROM Sharing_Queue__c
                WHERE Id = :row.Id
            ];
            SharingQueueService.ClaimResult claimed =
                SharingQueueService.claimQueues(toClaim, null);
            Sharing_Queue__c queue = claimed.queues[0];
            SharingQueueService.markFailed(
                queue,
                claimed.executionsByQueueId.get(queue.Id),
                shareEx,
                0);
        }

        Sharing_Queue__c after = [
            SELECT Status__c, Last_Error__c, Retry_Count__c
            FROM Sharing_Queue__c
            WHERE Id = :row.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_FAILED, after.Status__c);
        System.assertEquals(SharingQueueService.MAX_RETRIES, after.Retry_Count__c);
        System.assert(
            after.Last_Error__c != null && after.Last_Error__c.contains('Share insert failed'),
            after.Last_Error__c);
    }

    /**
     * @description Verifies resolve share level uses team member access without object configs.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testResolveShareLevelUsesTeamMemberAccessWithoutObjectConfigs() {
        insert new Team_Member_Config__c(
            Name = 'GLS TM access',
            Team_Member_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'AccountId',
            User_Field_Api_Name__c = 'OwnerId',
            Access_Level_Field_Api_Name__c = 'Description',
            Use_Team_Member_Access_Level__c = true,
            Is_Active__c = true,
            Application__c = 'GLS'
        );
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance('GLS');
        System.assertEquals(0, cfg.objectConfigs.size());
        System.assertEquals('Edit', SharingQueueService.resolveShareLevel(cfg, null, 'Create/Edit'));
        System.assertEquals('Read', SharingQueueService.resolveShareLevel(cfg, 'Unused', 'read'));
        System.assertEquals('Edit', SharingQueueService.resolveShareLevel(cfg, null, 'All'));
        System.assertEquals(null, SharingQueueService.resolveShareLevel(cfg, null, 'Full'));
    }

    /**
     * @description Verifies row cause for object ignores related child cause.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRowCauseForObjectIgnoresRelatedChildCause() {
        reset();
        insert new Sharing_Object_Config__c(
            Name = 'OCC Contact related',
            Child_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'AccountId',
            Row_Cause_Api_Name__c = 'TeamMemberAccess__c',
            Is_Active__c = true,
            Application__c = JobCatalogService.APP_APPLICATION1
        );
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance(JobCatalogService.APP_APPLICATION1);
        System.assertEquals(
            'TeamMemberAccess__c',
            SharingQueueService.rowCauseForObject(cfg, 'Contact'));
        System.assertEquals(
            'Manual',
            SharingQueueService.rowCauseForObject(cfg, 'Team_Member_Config__c'),
            'Main must not inherit a related object RowCause');
        System.assertEquals('Manual', SharingQueueService.rowCauseForObject(cfg, null));
        System.assertEquals('Manual', SharingQueueService.rowCauseForObject(null, 'Account'));
    }

    /**
     * @description Verifies related child object API name prefers payload.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testRelatedChildObjectApiNamePrefersPayload() {
        Sharing_Queue__c queue = new Sharing_Queue__c(
            Source_Object_Api_Name__c = 'Contact'
        );
        System.assertEquals(
            'Contact',
            SharingQueueService.relatedChildObjectApiName(queue));

        SharingQueueService.Payload payload = new SharingQueueService.Payload();
        payload.relatedObjectApiName = 'Account';
        queue.Payload__c = payload.toJson();
        System.assertEquals(
            'Account',
            SharingQueueService.relatedChildObjectApiName(queue));
        System.assertEquals(null, SharingQueueService.relatedChildObjectApiName(null));
    }

    /**
     * @description Verifies process claimed cheap queues completes share main direct in bulk.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testProcessClaimedCheapQueuesCompletesShareMainDirectInBulk() {
        reset();
        SharingQueueQueueable.resetEnqueueGuard();
        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>{
            pendingRow(
                JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
                mainDirectJob().Id,
                sourceId(1)),
            pendingRow(
                JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
                mainDirectJob().Id,
                sourceId(2))
        };
        insert rows;

        Test.startTest();
        new SharingQueueQueueable().execute(null);
        Test.stopTest();

        List<Sharing_Queue__c> after = [
            SELECT Status__c, Records_Processed__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id IN :rows
        ];
        System.assertEquals(2, after.size());
        for (Sharing_Queue__c row : after) {
            System.assertEquals(
                SharingQueueService.STATUS_COMPLETED,
                row.Status__c,
                row.Last_Error__c);
            System.assertEquals(0, row.Records_Processed__c);
        }
        for (Job_Execution__c execution : [
            SELECT SOQL_Queries_Used__c, SOQL_Queries_Limit__c, SOQL_Queries_Pct__c,
                   SOQL_Queries_Over_Warning__c,
                   Query_Rows_Used__c, Query_Rows_Limit__c,
                   DML_Statements_Used__c, DML_Statements_Limit__c,
                   DML_Rows_Used__c, DML_Rows_Limit__c,
                   CPU_Time_Used__c, CPU_Time_Limit__c
            FROM Job_Execution__c
            WHERE Sharing_Queue__c IN :rows
        ]) {
            System.assertNotEquals(null, execution.SOQL_Queries_Used__c);
            System.assert(execution.SOQL_Queries_Limit__c > 0, execution.SOQL_Queries_Limit__c);
            System.assertNotEquals(null, execution.SOQL_Queries_Pct__c);
            System.assertEquals(false, execution.SOQL_Queries_Over_Warning__c);
            System.assertNotEquals(null, execution.Query_Rows_Used__c);
            System.assert(execution.Query_Rows_Limit__c > 0);
            System.assertNotEquals(null, execution.DML_Statements_Used__c);
            System.assert(execution.DML_Statements_Limit__c > 0);
            System.assertNotEquals(null, execution.DML_Rows_Used__c);
            System.assert(execution.DML_Rows_Limit__c > 0);
            System.assertNotEquals(null, execution.CPU_Time_Used__c);
            System.assert(execution.CPU_Time_Limit__c > 0);
        }
        Job__c catalogJob = [
            SELECT SOQL_Queries_Warning_Pct__c, Query_Rows_Warning_Pct__c,
                   DML_Statements_Warning_Pct__c, DML_Rows_Warning_Pct__c,
                   CPU_Time_Warning_Pct__c
            FROM Job__c
            WHERE Id = :mainDirectJob().Id
        ];
        System.assertEquals(80, catalogJob.SOQL_Queries_Warning_Pct__c);
        System.assertEquals(80, catalogJob.Query_Rows_Warning_Pct__c);
        System.assertEquals(80, catalogJob.DML_Statements_Warning_Pct__c);
        System.assertEquals(80, catalogJob.DML_Rows_Warning_Pct__c);
        System.assertEquals(80, catalogJob.CPU_Time_Warning_Pct__c);
    }

    /**
     * @description Verifies process claimed cheap queues completes related record jobs in bulk.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testProcessClaimedCheapQueuesCompletesRelatedRecordJobsInBulk() {
        reset();
        SharingQueueQueueable.resetEnqueueGuard();
        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>{
            pendingRow(
                JobCatalogService.EVENT_RELATED_RECORD_CREATED,
                relatedJob().Id,
                sourceId(1)),
            pendingRow(
                JobCatalogService.EVENT_RELATED_RECORD_CREATED,
                relatedJob().Id,
                sourceId(2))
        };
        rows[0].Source_Object_Api_Name__c = 'Account';
        rows[1].Source_Object_Api_Name__c = 'Account';
        insert rows;

        Test.startTest();
        new SharingQueueQueueable().execute(null);
        Test.stopTest();

        List<Sharing_Queue__c> after = [
            SELECT Status__c, Last_Error__c
            FROM Sharing_Queue__c
            WHERE Id IN :rows
        ];
        System.assertEquals(2, after.size());
        for (Sharing_Queue__c row : after) {
            System.assertEquals(
                SharingQueueService.STATUS_COMPLETED,
                row.Status__c,
                row.Last_Error__c);
        }
    }

    /**
     * @description Verifies mark completed stamps passed batch peak.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMarkCompletedStampsPassedBatchPeak() {
        reset();
        Sharing_Queue__c row = pendingRow(
            JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            fanoutJob().Id,
            sourceId(1));
        insert row;
        SharingQueueService.ClaimResult claimed = SharingQueueService.claimQueues(
            new List<Sharing_Queue__c>{ row }, null);

        VolumeLimits peak = new VolumeLimits();
        peak.soql = 7;
        peak.soqlLimit = 200;
        peak.queryRows = 11;
        peak.queryRowsLimit = 50000;
        peak.dmlStatements = 3;
        peak.dmlStatementsLimit = 150;
        peak.dmlRows = 40;
        peak.dmlRowsLimit = 10000;
        peak.cpu = 900;
        peak.cpuLimit = 10000;

        SharingQueueService.markCompleted(
            claimed.queues,
            claimed.executionsByQueueId,
            new Map<Id, Integer>{ row.Id => 40 },
            peak);

        Job_Execution__c execution = [
            SELECT SOQL_Queries_Used__c, SOQL_Queries_Limit__c,
                   Query_Rows_Used__c, Query_Rows_Limit__c,
                   DML_Statements_Used__c, DML_Statements_Limit__c,
                   DML_Rows_Used__c, DML_Rows_Limit__c,
                   CPU_Time_Used__c, CPU_Time_Limit__c
            FROM Job_Execution__c
            WHERE Sharing_Queue__c = :row.Id
        ];
        System.assertEquals(7, execution.SOQL_Queries_Used__c);
        System.assertEquals(200, execution.SOQL_Queries_Limit__c);
        System.assertEquals(11, execution.Query_Rows_Used__c);
        System.assertEquals(50000, execution.Query_Rows_Limit__c);
        System.assertEquals(3, execution.DML_Statements_Used__c);
        System.assertEquals(150, execution.DML_Statements_Limit__c);
        System.assertEquals(40, execution.DML_Rows_Used__c);
        System.assertEquals(10000, execution.DML_Rows_Limit__c);
        System.assertEquals(900, execution.CPU_Time_Used__c);
        System.assertEquals(10000, execution.CPU_Time_Limit__c);
    }

    /**
     * @description Verifies batch finish leaves governors blank when execute did not run.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testBatchFinishLeavesGovernorsBlankWhenExecuteDidNotRun() {
        reset();
        Sharing_Queue__c row = pendingRow(
            JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            fanoutJob().Id,
            sourceId(1));
        SharingQueueService.Payload payload = new SharingQueueService.Payload();
        payload.relatedObjectApiNames = new List<String>{ 'DoesNotExist__c' };
        row.Payload__c = payload.toJson();
        insert row;

        Boolean drained = SharingQueueBatch.drainOnePendingSlice();
        System.assertEquals(true, drained);

        Job_Execution__c execution = [
            SELECT Status__c, SOQL_Queries_Used__c, SOQL_Queries_Limit__c,
                   CPU_Time_Used__c, CPU_Time_Limit__c
            FROM Job_Execution__c
            WHERE Sharing_Queue__c = :row.Id
        ];
        System.assertEquals(SharingQueueService.STATUS_COMPLETED, execution.Status__c);
        System.assertEquals(null, execution.SOQL_Queries_Used__c);
        System.assertEquals(null, execution.SOQL_Queries_Limit__c);
        System.assertEquals(null, execution.CPU_Time_Used__c);
        System.assertEquals(null, execution.CPU_Time_Limit__c);
    }

    /**
     * @description Verifies active worker count uses overlay.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testActiveWorkerCountUsesOverlay() {
        reset();
        SharingQueueService.activeQueueableOverride = 2;
        SharingQueueService.activeBatchOverride = 1;
        System.assertEquals(
            2,
            SharingQueueService.activeWorkerCount(SharingQueueService.QUEUEABLE_WORKER, null));
        System.assertEquals(
            1,
            SharingQueueService.activeWorkerCount(
                SharingQueueService.BATCH_WORKER,
                UserInfo.getUserId()));
        SharingQueueService.activeQueueableOverride = 0;
        SharingQueueService.activeBatchOverride = 0;
        System.assertEquals(
            0,
            SharingQueueService.activeWorkerCount(SharingQueueService.QUEUEABLE_WORKER, null));
        System.assertEquals(
            0,
            SharingQueueService.activeWorkerCount(SharingQueueService.BATCH_WORKER, null));
    }

    /**
     * @description Verifies kick workers no-ops when workers already active.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testKickWorkersNoOpsWhenWorkersAlreadyActive() {
        reset();
        SharingQueueService.activeQueueableOverride = 1;
        SharingQueueService.activeBatchOverride = 1;
        insertRelated(1);
        insertFanout(1);
        SharingQueueQueueable.resetEnqueueGuard();

        Test.startTest();
        SharingQueueService.kickWorkers();
        SharingQueueQueueable.resetEnqueueGuard();
        SharingQueueService.kickWorkers();
        Test.stopTest();

        System.assertEquals(
            0,
            asyncWorkerJobs(SharingQueueService.QUEUEABLE_WORKER),
            'second kick must not enqueue while a Queueable is active');
        System.assertEquals(
            0,
            asyncWorkerJobs(SharingQueueService.BATCH_WORKER),
            'second kick must not executeBatch while a Batch is active');
    }

    /**
     * @description Verifies enqueue once enqueues when no active queueable.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testEnqueueOnceEnqueuesWhenNoActiveQueueable() {
        reset();
        SharingQueueService.activeQueueableOverride = 0;
        SharingQueueService.activeBatchOverride = 0;
        SharingQueueQueueable.resetEnqueueGuard();

        Test.startTest();
        SharingQueueQueueable.enqueueOnce();
        Test.stopTest();

        System.assertEquals(1, asyncWorkerJobs(SharingQueueService.QUEUEABLE_WORKER));
    }

    /**
     * @description Verifies start if pending skips when batch already active.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testStartIfPendingSkipsWhenBatchAlreadyActive() {
        reset();
        SharingQueueService.activeBatchOverride = 1;
        insertFanout(1);

        Test.startTest();
        SharingQueueBatch.startIfPending();
        Test.stopTest();

        System.assertEquals(0, asyncWorkerJobs(SharingQueueService.BATCH_WORKER));
    }

    /**
     * @description Verifies start if pending starts when no active batch.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testStartIfPendingStartsWhenNoActiveBatch() {
        reset();
        SharingQueueService.activeBatchOverride = 0;
        Sharing_Queue__c row = pendingRow(
            JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
            fanoutJob().Id,
            sourceId(1));
        SharingQueueService.Payload payload = new SharingQueueService.Payload();
        payload.relatedObjectApiNames = new List<String>{ 'DoesNotExist__c' };
        row.Payload__c = payload.toJson();
        insert row;

        Test.startTest();
        SharingQueueBatch.startIfPending();
        Test.stopTest();

        System.assertEquals(1, asyncWorkerJobs(SharingQueueService.BATCH_WORKER));
    }

    /**
     * @description Verifies queueable execute chains when pending remain.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testQueueableExecuteChainsWhenPendingRemain() {
        reset();
        SharingQueueService.activeQueueableOverride = 0;
        SharingQueueService.activeBatchOverride = 0;
        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        Id jobId = mainDirectJob().Id;
        Integer total = SharingQueueService.QUEUEABLE_LIMIT + 1;
        for (Integer i = 0; i < total; i++) {
            rows.add(pendingRow(
                JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
                jobId,
                sourceId(i)));
        }
        insert rows;
        SharingQueueQueueable.resetEnqueueGuard();

        Test.startTest();
        new SharingQueueQueueable().execute(null);
        Integer completed = [
            SELECT COUNT()
            FROM Sharing_Queue__c
            WHERE Id IN :rows
            AND Status__c = :SharingQueueService.STATUS_COMPLETED
        ];
        Test.stopTest();

        System.assertEquals(
            1,
            asyncWorkerJobs(SharingQueueService.QUEUEABLE_WORKER),
            'execute must enqueue one successor when Pending Queueable rows remain');
        System.assertEquals(SharingQueueService.QUEUEABLE_LIMIT, completed);
    }

    /**
     * @description Verifies two hundred event inserts do not compact or exceed SOQL.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testTwoHundredEventInsertsDoNotCompactOrExceedSoql() {
        reset();
        SharingQueueService.activeQueueableOverride = 0;
        SharingQueueService.activeBatchOverride = 0;
        List<Sharing_Queue__c> rows = new List<Sharing_Queue__c>();
        for (Integer i = 0; i < 200; i++) {
            rows.add(new Sharing_Queue__c(
                Trigger_Event__c          = JobCatalogService.EVENT_TEAM_MEMBER_CREATED,
                Main_Record_Id__c         = mainId(),
                Main_Object_Api_Name__c   = 'User',
                Source_Record_Id__c       = sourceId(i),
                Source_Object_Api_Name__c = 'User',
                Application__c            = JobCatalogService.APP_APPLICATION1,
                Status__c                 = SharingQueueService.STATUS_PENDING,
                Is_Chain_Step__c          = false,
                Retry_Count__c            = 0
            ));
        }

        Integer soqlBefore = Limits.getQueries();
        insert rows;
        Integer soqlUsed = Limits.getQueries() - soqlBefore;
        System.assert(
            soqlUsed < Limits.getLimitQueries(),
            'Sharing Queue expand on 200 Team Member events must stay under the SOQL cap. Used='
                + soqlUsed);

        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM Sharing_Queue__c
                WHERE Trigger_Event__c = :JobCatalogService.EVENT_RECONCILE_SWEEP
            ],
            'compactOpenWork must not run on the originating insert');
        System.assertEquals(
            200,
            [
                SELECT COUNT()
                FROM Sharing_Queue__c
                WHERE Is_Chain_Step__c = true
                AND Status__c = :SharingQueueService.STATUS_BLOCKED
            ]);
        System.assertEquals(
            200,
            [
                SELECT COUNT()
                FROM Sharing_Queue__c
                WHERE Id IN :rows
                AND Job__r.Handler__c = :JobCatalogService.HANDLER_SHARE_MAIN_DIRECT
                AND Status__c = :SharingQueueService.STATUS_PENDING
            ]);
    }

    /**
     * @description Counts async jobs for the worker class.
     * @author Melissa Rainboldt
     * @param apexClassName Worker class name, SharingQueueQueueable or SharingQueueBatch.
     * @return The count produced for this test.
     */
    private static Integer asyncWorkerJobs(String apexClassName) {
        return [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE ApexClass.Name = :apexClassName
        ];
    }
}
