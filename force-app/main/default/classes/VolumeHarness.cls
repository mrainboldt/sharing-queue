/**
 * @description Runs a VolumeEngine and attributes governor usage to originating vs workers.
 * Call from tests after Test.startTest() so fixture DML is excluded.
 *
 * Apex Limits after Test.stopTest() do not include Queueable/Batch. Engines
 * that enqueue async work must drain it in drainOnce() so workers are counted.
 * @author Melissa Rainboldt
 */
public class VolumeHarness {
    public static final Integer MAX_WORKER_CALLS = 20;

    /**
     * @description Runs the engine, drains workers, and splits governor usage into originating,
     * workers, and total.
     * @author Melissa Rainboldt
     * @param scenario Label printed on the volume report.
     * @param engine Volume engine whose run and drainOnce are measured.
     * @return Originating usage, summed worker usage, and the total.
     */
    public static VolumeReport measure(String scenario, VolumeEngine engine) {
        VolumeReport report = new VolumeReport();
        report.engine = engine == null ? null : engine.name();
        report.scenario = scenario;
        report.workers = new VolumeLimits();
        if (engine == null) {
            report.originating = new VolumeLimits();
            report.total = new VolumeLimits();
            return report;
        }

        VolumeLimits before = VolumeLimits.capture();
        engine.run();
        report.originating = VolumeLimits.capture().diff(before);

        while (report.workerCalls < MAX_WORKER_CALLS) {
            VolumeLimits workerBefore = VolumeLimits.capture();
            if (!engine.drainOnce()) break;
            report.workers.add(VolumeLimits.capture().diff(workerBefore));
            report.workerCalls++;
        }

        report.total = report.originating.copy().add(report.workers);
        return report;
    }
}
