/**
 * @description Governor snapshot: used counts plus the Apex hard cap for this transaction.
 * capture / diff / add are for VolumeHarness. maxUsed is for Batch peaks.
 * @author Melissa Rainboldt
 */
public class VolumeLimits {
    public Integer soql = 0;
    public Integer queryRows = 0;
    public Integer dmlStatements = 0;
    public Integer dmlRows = 0;
    public Integer cpu = 0;

    public Integer soqlLimit = 0;
    public Integer queryRowsLimit = 0;
    public Integer dmlStatementsLimit = 0;
    public Integer dmlRowsLimit = 0;
    public Integer cpuLimit = 0;

    /**
     * @description Captures governors used and the hard caps in this transaction.
     * @author Melissa Rainboldt
     * @return A snapshot of used counts and hard caps.
     */
    public static VolumeLimits capture() {
        VolumeLimits snap = new VolumeLimits();
        snap.soql = Limits.getQueries();
        snap.queryRows = Limits.getQueryRows();
        snap.dmlStatements = Limits.getDmlStatements();
        snap.dmlRows = Limits.getDmlRows();
        snap.cpu = Limits.getCpuTime();
        snap.soqlLimit = Limits.getLimitQueries();
        snap.queryRowsLimit = Limits.getLimitQueryRows();
        snap.dmlStatementsLimit = Limits.getLimitDmlStatements();
        snap.dmlRowsLimit = Limits.getLimitDmlRows();
        snap.cpuLimit = Limits.getLimitCpuTime();
        return snap;
    }

    /**
     * @description Returns the increase in used governors since the earlier snapshot, and copies
     * this snapshot's caps.
     * @author Melissa Rainboldt
     * @param before Earlier governor snapshot to subtract.
     * @return The delta of used counts since before.
     */
    public VolumeLimits diff(VolumeLimits before) {
        VolumeLimits delta = new VolumeLimits();
        Integer baseSoql = before == null ? 0 : before.soql;
        Integer baseQueryRows = before == null ? 0 : before.queryRows;
        Integer baseDml = before == null ? 0 : before.dmlStatements;
        Integer baseDmlRows = before == null ? 0 : before.dmlRows;
        Integer baseCpu = before == null ? 0 : before.cpu;
        delta.soql = soql - baseSoql;
        delta.queryRows = queryRows - baseQueryRows;
        delta.dmlStatements = dmlStatements - baseDml;
        delta.dmlRows = dmlRows - baseDmlRows;
        delta.cpu = cpu - baseCpu;
        copyLimitsOnto(delta);
        return delta;
    }

    /**
     * @description Returns a copy of the used counts and caps.
     * @author Melissa Rainboldt
     * @return A copy of this snapshot.
     */
    public VolumeLimits copy() {
        VolumeLimits cloneSnap = new VolumeLimits();
        cloneSnap.soql = soql;
        cloneSnap.queryRows = queryRows;
        cloneSnap.dmlStatements = dmlStatements;
        cloneSnap.dmlRows = dmlRows;
        cloneSnap.cpu = cpu;
        copyLimitsOnto(cloneSnap);
        return cloneSnap;
    }

    /**
     * @description Adds the other snapshot's used counts into this one and returns this snapshot.
     * @author Melissa Rainboldt
     * @param other Used counts to add into this snapshot.
     * @return This snapshot after the other used counts are added.
     */
    public VolumeLimits add(VolumeLimits other) {
        if (other == null) return this;
        soql += other.soql;
        queryRows += other.queryRows;
        dmlStatements += other.dmlStatements;
        dmlRows += other.dmlRows;
        cpu += other.cpu;
        return this;
    }

    /**
     * @description Higher used on each metric independently. Limits come from a snapshot
     * that already has caps (Batch execute).
     * @author Melissa Rainboldt
     * @param other Snapshot whose higher used count is kept on each metric.
     * @return A snapshot of the higher used count on each metric.
     */
    public VolumeLimits maxUsed(VolumeLimits other) {
        if (other == null) return this;
        VolumeLimits peak = copy();
        if (other.soql > peak.soql) peak.soql = other.soql;
        if (other.queryRows > peak.queryRows) peak.queryRows = other.queryRows;
        if (other.dmlStatements > peak.dmlStatements) {
            peak.dmlStatements = other.dmlStatements;
        }
        if (other.dmlRows > peak.dmlRows) peak.dmlRows = other.dmlRows;
        if (other.cpu > peak.cpu) peak.cpu = other.cpu;
        if (peak.soqlLimit == null || peak.soqlLimit == 0) {
            other.copyLimitsOnto(peak);
        }
        return peak;
    }

    /**
     * @description Writes used and limit fields onto the job execution.
     * @author Melissa Rainboldt
     * @param execution Job execution for the queue. Null when one was not created.
     * @return void
     */
    public void applyTo(Job_Execution__c execution) {
        if (execution == null) return;
        execution.SOQL_Queries_Used__c = soql;
        execution.SOQL_Queries_Limit__c = soqlLimit;
        execution.Query_Rows_Used__c = queryRows;
        execution.Query_Rows_Limit__c = queryRowsLimit;
        execution.DML_Statements_Used__c = dmlStatements;
        execution.DML_Statements_Limit__c = dmlStatementsLimit;
        execution.DML_Rows_Used__c = dmlRows;
        execution.DML_Rows_Limit__c = dmlRowsLimit;
        execution.CPU_Time_Used__c = cpu;
        execution.CPU_Time_Limit__c = cpuLimit;
    }

    /**
     * @description Returns the used amount as a percent of the limit, or n/a when the limit is
     * missing.
     * @author Melissa Rainboldt
     * @param usageAmt Governor amount already used.
     * @param limitAmt Hard cap for that governor.
     * @return The percent text, or n/a when the limit is 0 or null.
     */
    public String getUsagePercentage(Integer usageAmt, Integer limitAmt) {
        Integer used = usageAmt == null ? 0 : usageAmt;
        if (limitAmt == null || limitAmt == 0) return 'n/a';
        return ((Decimal.valueOf(used) / limitAmt) * 100).setScale(2) + '%';
    }

    /**
     * @description Formats used, limit, and percent for each governor.
     * @author Melissa Rainboldt
     * @return Used, limit, and percent for SOQL, query rows, DML, DML rows, and CPU.
     */
    public String toLine() {
        return 'soql:  ' + soql + '/' + soqlLimit
            + ' (' + getUsagePercentage(soql, soqlLimit) + ')'
            + ';\nqueryRows:  ' + queryRows + '/' + queryRowsLimit
            + ' (' + getUsagePercentage(queryRows, queryRowsLimit) + ')'
            + ';\ndml:  ' + dmlStatements + '/' + dmlStatementsLimit
            + ' (' + getUsagePercentage(dmlStatements, dmlStatementsLimit) + ')'
            + ';\ndmlRows:  ' + dmlRows + '/' + dmlRowsLimit
            + ' (' + getUsagePercentage(dmlRows, dmlRowsLimit) + ')'
            + ';\ncpu:  ' + cpu + '/' + cpuLimit
            + ' (' + getUsagePercentage(cpu, cpuLimit) + ')';
    }

    /**
     * @description Copies this snapshot's hard caps onto the target.
     * @author Melissa Rainboldt
     * @param target Snapshot that receives the hard caps.
     * @return void
     */
    private void copyLimitsOnto(VolumeLimits target) {
        target.soqlLimit = soqlLimit;
        target.queryRowsLimit = queryRowsLimit;
        target.dmlStatementsLimit = dmlStatementsLimit;
        target.dmlRowsLimit = dmlRowsLimit;
        target.cpuLimit = cpuLimit;
    }
}
