/**
 * @description Proves VolumeHarness attributes originating vs worker Limits without sharing data.
 * @author Melissa Rainboldt
 */
@IsTest
private class VolumeHarnessTest {
    /**
     * @description Test engine that runs one query in run and a fixed number of Account inserts in
     * drainOnce.
     * @author Melissa Rainboldt
     */
    private class FakeEngine extends VolumeEngine {
        Integer remainingWorkers;

        /**
         * @description Sets how many worker steps drainOnce will perform.
         * @author Melissa Rainboldt
         * @param workerSteps How many worker steps the fake engine should run.
         * @return A new FakeEngine instance.
         */
        FakeEngine(Integer workerSteps) {
            remainingWorkers = workerSteps;
        }

        /**
         * @description Returns the Fake label asserted by the harness test.
         * @author Melissa Rainboldt
         * @return Fake.
         */
        public override String name() {
            return 'Fake';
        }

        /**
         * @description Runs one User query so originating SOQL is non-zero.
         * @author Melissa Rainboldt
         * @return void
         */
        public override void run() {
            Integer ignored = [SELECT COUNT() FROM User WHERE Id = :UserInfo.getUserId()];
        }

        /**
         * @description Inserts one Account per remaining worker step. Returns false when none
         * remain.
         * @author Melissa Rainboldt
         * @return True when a worker Account was inserted.
         */
        public override Boolean drainOnce() {
            if (remainingWorkers <= 0) return false;
            remainingWorkers--;
            insert new Account(Name = 'VolumeHarness worker');
            return true;
        }
    }

    /**
     * @description Verifies measure splits originating and workers.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMeasureSplitsOriginatingAndWorkers() {
        Test.startTest();
        VolumeReport report = VolumeHarness.measure('FakeRun', new FakeEngine(1));
        Test.stopTest();

        System.assertEquals('Fake', report.engine);
        System.assertEquals('FakeRun', report.scenario);
        System.assertEquals(1, report.workerCalls);
        System.assert(
            report.originating.soql >= 1,
            'Originating should count the User query: ' + report.originating.toLine());
        System.assert(
            report.workers.dmlStatements >= 1,
            'Workers should count the Account insert: ' + report.workers.toLine());
        System.assertEquals(
            report.originating.soql + report.workers.soql,
            report.total.soql);
        System.assertEquals(
            report.originating.dmlStatements + report.workers.dmlStatements,
            report.total.dmlStatements);
        System.assert(
            report.toLine().startsWith('VOLUME_COMPARE'),
            report.toLine());
    }

    /**
     * @description Verifies unwired engine throws.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testUnwiredEngineThrows() {
        Boolean threw = false;
        try {
            VolumeHarness.measure('Unwired', new VolumeEngine());
        } catch (VolumeEngine.NotWiredException e) {
            threw = true;
        }
        System.assert(threw);
    }

    /**
     * @description Verifies diff and add.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testDiffAndAdd() {
        VolumeLimits before = new VolumeLimits();
        before.soql = 2;
        before.cpu = 10;
        VolumeLimits after = new VolumeLimits();
        after.soql = 5;
        after.cpu = 40;
        VolumeLimits delta = after.diff(before);
        System.assertEquals(3, delta.soql);
        System.assertEquals(30, delta.cpu);
        VolumeLimits sum = delta.copy().add(before);
        System.assertEquals(5, sum.soql);
        System.assertEquals(2, before.soql);
    }

    /**
     * @description Verifies capture limits max used and to line.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testCaptureLimitsMaxUsedAndToLine() {
        VolumeLimits snap = VolumeLimits.capture();
        System.assert(snap.soqlLimit > 0, snap.toLine());
        System.assert(snap.queryRowsLimit > 0);
        System.assert(snap.dmlStatementsLimit > 0);
        System.assert(snap.dmlRowsLimit > 0);
        System.assert(snap.cpuLimit > 0);
        System.assert(
            snap.toLine().contains('soql:  ' + snap.soql + '/' + snap.soqlLimit),
            snap.toLine());

        VolumeLimits first = new VolumeLimits();
        first.soql = 2;
        first.cpu = 50;
        first.soqlLimit = 100;
        first.cpuLimit = 10000;
        VolumeLimits second = new VolumeLimits();
        second.soql = 9;
        second.cpu = 10;
        second.soqlLimit = 100;
        second.cpuLimit = 10000;
        VolumeLimits peak = first.maxUsed(second);
        System.assertEquals(9, peak.soql);
        System.assertEquals(50, peak.cpu);
        System.assertEquals(100, peak.soqlLimit);
        System.assertEquals(10000, peak.cpuLimit);

        VolumeLimits copied = snap.copy();
        System.assertEquals(snap.soqlLimit, copied.soqlLimit);
        copied.add(first);
        System.assertEquals(snap.soqlLimit, copied.soqlLimit);
        System.assertEquals(snap.soql + 2, copied.soql);

        Job_Execution__c execution = new Job_Execution__c();
        peak.applyTo(execution);
        System.assertEquals(9, execution.SOQL_Queries_Used__c);
        System.assertEquals(100, execution.SOQL_Queries_Limit__c);
        System.assertEquals(50, execution.CPU_Time_Used__c);
        System.assertEquals(10000, execution.CPU_Time_Limit__c);
    }
}
