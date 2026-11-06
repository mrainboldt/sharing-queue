trigger SharingQueueTrigger on Sharing_Queue__c (after insert) {
    if (Trigger.isAfter && Trigger.isInsert) {
        SharingQueueTriggerHandler.afterInsert(Trigger.new);
    }
}