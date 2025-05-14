import Decimal from 'decimal.js';

export interface Transaction {
  amount: number;
  date: Date;
}

// Configure Decimal for financial calculations
Decimal.set({ precision: 20, rounding: Decimal.ROUND_HALF_UP });

export function calculateRequiredInterestRate(
  transactions: Transaction[],
  loanAmount: number,
  termInMonths: number = 24,
  dscr: number = 1.25,
  minInterestRate: number = 1,
  maxInterestRate: number = 10
): number {
  // Input validation
  if (!Number.isFinite(loanAmount) || loanAmount <= 0) {
    throw new Error('Invalid loan amount');
  }
  if (!Number.isFinite(termInMonths) || termInMonths <= 0) {
    throw new Error('Invalid loan term');
  }
  if (!Number.isFinite(dscr) || dscr <= 0) {
    throw new Error('Invalid DSCR');
  }

  // Convert inputs to Decimal for precise calculations
  const loanAmountD = new Decimal(loanAmount);
  const dscrD = new Decimal(dscr);
  const termInMonthsD = new Decimal(termInMonths);

  // Group transactions by month and calculate NOI for each month
  const noiByMonth = transactions.reduce((acc, tx) => {
    const date = new Date(tx.date);
    const monthKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
    acc[monthKey] = (acc[monthKey] || new Decimal(0)).plus(new Decimal(tx.amount));
    return acc;
  }, {} as Record<string, Decimal>);

  // Calculate average monthly NOI
  const months = Object.keys(noiByMonth);
  if (months.length === 0) {
    return new Decimal(minInterestRate).times(100).toDecimalPlaces(6).toNumber();
  }

  const monthlyNOI = Object.values(noiByMonth)
    .reduce((sum, noi) => sum.plus(noi), new Decimal(0))
    .dividedBy(new Decimal(months.length));

  if (monthlyNOI.isZero() || monthlyNOI.isNegative()) {
    return new Decimal(minInterestRate).times(100).toDecimalPlaces(6).toNumber();
  }

  // Binary search to find the minimum interest rate that satisfies DSCR
  let low = new Decimal(minInterestRate).dividedBy(100); // Convert to decimal (0.01 for 1%)
  let high = new Decimal(maxInterestRate).dividedBy(100); // Convert to decimal (0.10 for 10%)
  const tolerance = new Decimal('0.0001');
  const twelve = new Decimal(12);

  while (high.minus(low).abs().greaterThan(tolerance)) {
    const mid = low.plus(high).dividedBy(2);
    const monthlyRate = mid.dividedBy(twelve);

    // Calculate monthly payment using the standard loan payment formula
    const monthlyPayment = calculateMonthlyPayment(
      loanAmountD,
      monthlyRate,
      termInMonthsD
    );

    // Calculate total payments over the loan term
    const totalPayments = monthlyPayment.times(termInMonthsD);
    const totalNOI = monthlyNOI.times(termInMonthsD);

    // Calculate DSCR over the entire loan term
    const actualDSCR = totalNOI.dividedBy(totalPayments);

    if (actualDSCR.lessThan(dscrD)) {
      high = mid;
    } else {
      low = mid;
    }
  }

  // Convert back to percentage and return with 6 decimal places
  return high.times(100).toDecimalPlaces(6).toNumber();
}

/**
 * Calculates the monthly payment for a loan using the standard loan payment formula
 * using high-precision decimal arithmetic
 */
function calculateMonthlyPayment(
  principal: Decimal,
  monthlyRate: Decimal,
  numberOfPayments: Decimal
): Decimal {
  // Handle edge case of zero interest rate
  if (monthlyRate.isZero()) {
    return principal.dividedBy(numberOfPayments);
  }

  const one = new Decimal(1);
  const rateFactorPow = one.plus(monthlyRate).pow(numberOfPayments);
  
  return principal.times(monthlyRate.times(rateFactorPow))
    .dividedBy(rateFactorPow.minus(one));
}