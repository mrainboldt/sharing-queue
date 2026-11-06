/**
 * @description Drains Pending Sharing_Queue__c rows whose catalog Job is Queueable.
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueQueueable implements Queueable {

    private static Boolean enqueuedThisTx = false;

    /**
     * @description Enqueues at most one SharingQueueQueueable when a slot is free and no other
     * worker of that class is already queued. Pending rows stay put when the slot is full.
     * @author Melissa Rainboldt
     * @return void
     */
    public static void enqueueOnce() {
        enqueueOnce(null);
    }

    /**
     * @description Enqueues at most one SharingQueueQueueable when a slot is free and no other
     * worker of that class is already queued. Pending rows stay put when the slot is full.
     * @author Melissa Rainboldt
     * @param excludeJobId Running Queueable job to ignore so this execution can chain a successor.
     * @return void
     */
    public static void enqueueOnce(Id excludeJobId) {
        if (SharingQueueService.suppressAsyncKick) return;
        if (enqueuedThisTx) return;
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
        if (SharingQueueService.activeWorkerCount(
                SharingQueueService.QUEUEABLE_WORKER, excludeJobId) > 0) {
            return;
        }
        enqueuedThisTx = true;
        try {
            System.enqueueJob(new SharingQueueQueueable());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'SharingQueueQueueable.enqueueOnce skipped: ' + e.getMessage());
        }
    }

    /**
     * @description Clears the once-per-transaction enqueue flag.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestVisible
    static void resetEnqueueGuard() {
        enqueuedThisTx = false;
    }

    /**
     * @description Claims pending Queueable rows, drains them, chains another Queueable when work
     * remains, then starts the Batch worker.
     * @author Melissa Rainboldt
     * @param ctx Queueable context. Null when the job is drained inline in a test.
     * @return void
     */
    public void execute(QueueableContext ctx) {
        enqueuedThisTx = false;
        SharingQueueService.compactOpenWork();
        String queueableKind = JobCatalogService.PROCESSOR_QUEUEABLE;
        Integer take = SharingQueueService.QUEUEABLE_LIMIT;
        List<Sharing_Queue__c> queues = [SELECT Id
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
                                        WHERE Status__c = :SharingQueueService.STATUS_PENDING
                                            AND Job__c != null
                                            AND Job__r.Processor__c = :queueableKind
                                        LIMIT :take
                                        FOR UPDATE
                                        ];
        if (!queues.isEmpty()) {
            Id asyncId = ctx == null ? null : ctx.getJobId();
            SharingQueueService.ClaimResult claimed = SharingQueueService.claimQueues(queues, asyncId);
            SharingQueueService.processClaimedCheapQueues(claimed);

            Integer remaining = [
                SELECT COUNT()
                FROM Sharing_Queue__c
                WHERE Status__c = :SharingQueueService.STATUS_PENDING
                AND Job__c != null
                AND Job__r.Processor__c = :queueableKind
                LIMIT 1
            ];
            if (remaining > 0) {
                enqueueOnce(ctx == null ? null : ctx.getJobId());
            }
        }
        SharingQueueBatch.startIfPending();
    }
}
