/**
 * @description Releases stuck claims, compacts open work, and kicks workers on a schedule.
 * System.schedule('Sharing Queue Reconcile', '0 0/5 * * * ?', new SharingQueueReconcileSchedulable());
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueReconcileSchedulable implements Schedulable {

    /**
     * @description Releases stuck Processing rows, compacts open work, kicks the Queueable, and
     * starts the Batch worker.
     * @author Melissa Rainboldt
     * @param sc Schedulable context supplied by the platform.
     * @return void
     */
    public void execute(SchedulableContext sc) {
        SharingQueueService.unstickClaims();
        SharingQueueService.compactOpenWork();
        SharingQueueService.kickWorkers();
        SharingQueueBatch.startIfPending();
    }
}
