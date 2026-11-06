/**
 * @description After insert: expand event rows (Job__c blank) onto the catalog chain.
 * After update: if a caller outside Queueable/Batch moved Status to Pending,
 * kick workers. Worker DML on this object must not enqueue from here.
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueTriggerHandler {

    /**
     * @description Expands event rows whose Job is still blank onto the catalog chain.
     * @author Melissa Rainboldt
     * @param newRows Sharing Queue rows inserted in this trigger transaction.
     * @return void
     */
    public static void afterInsert(List<Sharing_Queue__c> newRows) {
        SharingQueueService.expandChains(newRows);
    }
}
