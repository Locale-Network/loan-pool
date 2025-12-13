/**
 * Configuration module for Cartesi rollup settings.
 * Reads from environment variables with sensible defaults.
 */

/**
 * Whether interest rate changes require approval before being applied.
 * Set REQUIRE_RATE_APPROVAL=true in environment to enable.
 */
export function requireRateApproval(): boolean {
  const envValue = process.env.REQUIRE_RATE_APPROVAL;
  return envValue === 'true' || envValue === '1';
}

/**
 * Default DSCR target for loan approval.
 */
export function getDefaultDscrTarget(): number {
  const envValue = process.env.DEFAULT_DSCR_TARGET;
  if (envValue) {
    const parsed = parseFloat(envValue);
    if (!isNaN(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return 1.25;
}

/**
 * Maximum transactions per sync to prevent spam.
 */
export function getMaxTransactionsPerSync(): number {
  const envValue = process.env.MAX_TRANSACTIONS_PER_SYNC;
  if (envValue) {
    const parsed = parseInt(envValue, 10);
    if (!isNaN(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return 500;
}
