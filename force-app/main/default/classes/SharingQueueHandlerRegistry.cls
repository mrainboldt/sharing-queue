/**
 * @description Resolves Job.Handler__c to a SharingQueueHandler.
 * Picklist API names may use underscores; class names do not.
 * Type.forName is tried with underscores stripped, then the raw value.
 * @author Melissa Rainboldt
 */
public without sharing class SharingQueueHandlerRegistry {

    private static Map<String, SharingQueueHandler> cache =
        new Map<String, SharingQueueHandler>();

    /**
     * @description Returns the handler instance for Job.Handler__c. Underscores in the picklist
     * value are stripped before the class name is tried.
     * @author Melissa Rainboldt
     * @param handler Job Handler__c value or Apex class name.
     * @return The cached handler instance.
     */
    public static SharingQueueHandler resolve(String handler) {
        if (String.isBlank(handler)) {
            throw new SharingConfigService.SharingException('Job has no Handler__c');
        }
        SharingQueueHandler cached = cache.get(handler);
        if (cached != null) return cached;

        Type handlerType = Type.forName(handler.replace('_', ''));
        if (handlerType == null) {
            handlerType = Type.forName(handler);
        }
        if (handlerType == null) {
            throw new SharingConfigService.SharingException(
                'No Apex class for Handler ' + handler
                    + '. Expected a SharingQueueHandler named '
                    + handler.replace('_', '') + '.');
        }
        Object instance = handlerType.newInstance();
        if (!(instance instanceof SharingQueueHandler)) {
            throw new SharingConfigService.SharingException(
                handler + ' must extend SharingQueueHandler');
        }
        SharingQueueHandler resolved = (SharingQueueHandler) instance;
        cache.put(handler, resolved);
        return resolved;
    }

    /**
     * @description Returns the handler, or null when the name is blank or not a
     * SharingQueueHandler.
     * @author Melissa Rainboldt
     * @param handler Job Handler__c value or Apex class name.
     * @return The handler, or null when it cannot be resolved.
     */
    public static SharingQueueHandler tryResolve(String handler) {
        try {
            return resolve(handler);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * @description Clears the handler instance cache.
     * @author Melissa Rainboldt
     * @return void
     */
    @TestVisible
    static void resetCache() {
        cache = new Map<String, SharingQueueHandler>();
    }
}
