import { InspectHandler, InspectQuery } from '../router';
import { getDatabaseStats } from '../db';

/**
 * Handle inspect query for database statistics.
 * Provides aggregate data safe for public viewing.
 */
export const handleInspectStats: InspectHandler = async (query: InspectQuery) => {
  const stats = getDatabaseStats();

  return {
    statistics: {
      total_borrowers: stats.total_borrowers,
      total_loans: stats.total_loans,
      total_transactions: stats.total_transactions,
      loans_by_status: stats.loans_by_status,
      average_loan_amount: stats.average_loan_amount.toFixed(2),
      average_dscr: stats.average_dscr ? stats.average_dscr.toFixed(4) : null,
    },
    timestamp: new Date().toISOString(),
  };
};
