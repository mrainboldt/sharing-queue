/**
 * @description One VolumeHarness.measure() result: originating transaction, summed workers,
 * and total. Log with toLine() at WARN.
 * @author Melissa Rainboldt
 */
public class VolumeReport {
    public String engine;
    public String scenario;
    public VolumeLimits originating;
    public VolumeLimits workers;
    public VolumeLimits total;
    public Integer workerCalls = 0;

    /**
     * @description Formats the VOLUME_COMPARE line for originating, worker, and total usage.
     * @author Melissa Rainboldt
     * @return The VOLUME_COMPARE log text.
     */
    public String toLine() {
        VolumeLimits orig = originating == null ? new VolumeLimits() : originating;
        VolumeLimits work = workers == null ? new VolumeLimits() : workers;
        VolumeLimits tot = total == null ? orig.copy().add(work) : total;
        return 'VOLUME_COMPARE'
            + '| engine: ' + engine
            + '| scenario: ' + scenario
            + '| workerCalls: ' + workerCalls
            + '\noriginating: ' + orig.toLine()
            + '\nworkers: ' + work.toLine()
            + '\ntotal: ' + tot.toLine();
    }
}
