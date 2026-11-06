/**
 * @description Pluggable volume subject. Subclasses hold their own workload and implement
 * originating work in run() and optional synchronous worker steps in drainOnce().
 * @author Melissa Rainboldt
 */
public virtual class VolumeEngine {
    /**
     * @description Thrown when VolumeEngine.run is called before a subclass implements it.
     * @author Melissa Rainboldt
     */
    public class NotWiredException extends Exception {}

    /**
     * @description Returns the engine label. The base implementation returns unwired.
     * @author Melissa Rainboldt
     * @return The engine label.
     */
    public virtual String name() {
        return 'unwired';
    }

    /**
     * @description Runs the originating work. The base implementation throws NotWiredException.
     * @author Melissa Rainboldt
     * @return void
     */
    public virtual void run() {
        throw new NotWiredException('Wire VolumeEngine.run() for ' + name());
    }

    /**
     * @description One synchronous worker execute. Return false when nothing is pending.
     * Default is a sync engine (no workers).
     * @author Melissa Rainboldt
     * @return True when a worker step ran. The base returns false.
     */
    public virtual Boolean drainOnce() {
        return false;
    }
}
