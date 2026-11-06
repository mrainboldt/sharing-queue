/**
 * @description Reads org-wide Sharing Queue switch and compaction thresholds from
 * Sharing_Queue_Setting__mdt Default. Blank number fields use packaged
 * defaults. Tests overlay values without CMT DML.
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueSettings {

    public static final String DEVELOPER_NAME = 'Default';

    public static final Integer DEFAULT_RELATED_BUNCH = 10;
    public static final Integer DEFAULT_FANOUT_SOME   = 3;
    public static final Integer DEFAULT_MIXED_PRODUCT = 15;
    public static final Integer DEFAULT_OPEN_WORK     = 20;

    @TestVisible static Integer relatedBunchOverride;
    @TestVisible static Integer fanoutSomeOverride;
    @TestVisible static Integer mixedProductOverride;
    @TestVisible static Integer openWorkOverride;
    @TestVisible static Boolean useSharingQueueOverride;

    private static Sharing_Queue_Setting__mdt cached;

    /**
     * @description Clears the metadata cache and test overrides.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestVisible
    static void resetCache() {
        cached = null;
        relatedBunchOverride = null;
        fanoutSomeOverride = null;
        mixedProductOverride = null;
        openWorkOverride = null;
        useSharingQueueOverride = null;
    }

    /**
     * @description When false, enqueue methods insert nothing. Missing Default record
     * keeps the queue on so tests and first deploy are not fail-closed.
     * @author Melissa Rainboldt
     * @return True when enqueue is enabled. A missing Default record stays enabled.
     */
    public static Boolean useSharingQueue() {
        if (useSharingQueueOverride != null) return useSharingQueueOverride;
        return SharingUtils.isSharingQueueEnabled();
    }

    /**
     * @description Returns how many related-record rows on one main promote that main to reconcile.
     * @author Melissa Rainboldt
     * @return The related-record bunch threshold.
     */
    public static Integer relatedBunchThreshold() {
        if (relatedBunchOverride != null) return relatedBunchOverride;
        return threshold(record().Related_Bunch_Threshold__c, DEFAULT_RELATED_BUNCH);
    }

    /**
     * @description Returns how many fan-out rows on one main promote that main to reconcile.
     * @author Melissa Rainboldt
     * @return The fan-out threshold.
     */
    public static Integer fanoutSomeThreshold() {
        if (fanoutSomeOverride != null) return fanoutSomeOverride;
        return threshold(record().Fanout_Some_Threshold__c, DEFAULT_FANOUT_SOME);
    }

    /**
     * @description Returns the related-times-fan-out product that promotes a main to reconcile.
     * @author Melissa Rainboldt
     * @return The mixed-product threshold.
     */
    public static Integer mixedProductThreshold() {
        if (mixedProductOverride != null) return mixedProductOverride;
        return threshold(record().Mixed_Product_Threshold__c, DEFAULT_MIXED_PRODUCT);
    }

    /**
     * @description Returns how many open related plus fan-out rows promote a main to reconcile.
     * @author Melissa Rainboldt
     * @return The open-work threshold.
     */
    public static Integer openWorkThreshold() {
        if (openWorkOverride != null) return openWorkOverride;
        return threshold(record().Open_Work_Threshold__c, DEFAULT_OPEN_WORK);
    }

    /**
     * @description Returns the metadata number, or the packaged default when the field is blank.
     * @author Melissa Rainboldt
     * @param configured Custom metadata number. Null uses the packaged default.
     * @param fallback Packaged default used when the metadata field is blank.
     * @return The configured integer, or fallback when configured is null.
     */
    private static Integer threshold(Decimal configured, Integer fallback) {
        if (configured == null) return fallback;
        return configured.intValue();
    }

    /**
     * @description Returns the Default Sharing Queue Setting row, or an empty row when it is
     * missing.
     * @author Melissa Rainboldt
     * @return The Default custom metadata row, or a blank in-memory row when none exists.
     */
    private static Sharing_Queue_Setting__mdt record() {
        if (cached != null) return cached;
        List<Sharing_Queue_Setting__mdt> rows = [
            SELECT Related_Bunch_Threshold__c
                 , Fanout_Some_Threshold__c
                 , Mixed_Product_Threshold__c
                 , Open_Work_Threshold__c
            FROM Sharing_Queue_Setting__mdt
            WHERE DeveloperName = :DEVELOPER_NAME
            LIMIT 1
        ];
        cached = rows.isEmpty() ? new Sharing_Queue_Setting__mdt() : rows[0];
        return cached;
    }
}
