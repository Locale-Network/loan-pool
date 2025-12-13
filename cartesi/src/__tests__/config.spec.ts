import { requireRateApproval, getDefaultDscrTarget, getMaxTransactionsPerSync } from '../config';

describe('Config', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    // Reset environment before each test
    jest.resetModules();
    process.env = { ...originalEnv };
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  describe('requireRateApproval', () => {
    it('should return false when REQUIRE_RATE_APPROVAL is not set', () => {
      delete process.env.REQUIRE_RATE_APPROVAL;
      expect(requireRateApproval()).toBe(false);
    });

    it('should return true when REQUIRE_RATE_APPROVAL is "true"', () => {
      process.env.REQUIRE_RATE_APPROVAL = 'true';
      expect(requireRateApproval()).toBe(true);
    });

    it('should return true when REQUIRE_RATE_APPROVAL is "1"', () => {
      process.env.REQUIRE_RATE_APPROVAL = '1';
      expect(requireRateApproval()).toBe(true);
    });

    it('should return false when REQUIRE_RATE_APPROVAL is "false"', () => {
      process.env.REQUIRE_RATE_APPROVAL = 'false';
      expect(requireRateApproval()).toBe(false);
    });

    it('should return false when REQUIRE_RATE_APPROVAL is "0"', () => {
      process.env.REQUIRE_RATE_APPROVAL = '0';
      expect(requireRateApproval()).toBe(false);
    });

    it('should return false for other values', () => {
      process.env.REQUIRE_RATE_APPROVAL = 'yes';
      expect(requireRateApproval()).toBe(false);

      process.env.REQUIRE_RATE_APPROVAL = 'TRUE';
      expect(requireRateApproval()).toBe(false);
    });
  });

  describe('getDefaultDscrTarget', () => {
    it('should return 1.25 when DEFAULT_DSCR_TARGET is not set', () => {
      delete process.env.DEFAULT_DSCR_TARGET;
      expect(getDefaultDscrTarget()).toBe(1.25);
    });

    it('should return parsed value when DEFAULT_DSCR_TARGET is set', () => {
      process.env.DEFAULT_DSCR_TARGET = '1.5';
      expect(getDefaultDscrTarget()).toBe(1.5);
    });

    it('should return 1.25 for invalid values', () => {
      process.env.DEFAULT_DSCR_TARGET = 'invalid';
      expect(getDefaultDscrTarget()).toBe(1.25);
    });

    it('should return 1.25 for zero', () => {
      process.env.DEFAULT_DSCR_TARGET = '0';
      expect(getDefaultDscrTarget()).toBe(1.25);
    });

    it('should return 1.25 for negative values', () => {
      process.env.DEFAULT_DSCR_TARGET = '-1.5';
      expect(getDefaultDscrTarget()).toBe(1.25);
    });

    it('should handle decimal values', () => {
      process.env.DEFAULT_DSCR_TARGET = '1.35';
      expect(getDefaultDscrTarget()).toBe(1.35);

      process.env.DEFAULT_DSCR_TARGET = '2.0';
      expect(getDefaultDscrTarget()).toBe(2.0);
    });
  });

  describe('getMaxTransactionsPerSync', () => {
    it('should return 500 when MAX_TRANSACTIONS_PER_SYNC is not set', () => {
      delete process.env.MAX_TRANSACTIONS_PER_SYNC;
      expect(getMaxTransactionsPerSync()).toBe(500);
    });

    it('should return parsed value when MAX_TRANSACTIONS_PER_SYNC is set', () => {
      process.env.MAX_TRANSACTIONS_PER_SYNC = '1000';
      expect(getMaxTransactionsPerSync()).toBe(1000);
    });

    it('should return 500 for invalid values', () => {
      process.env.MAX_TRANSACTIONS_PER_SYNC = 'invalid';
      expect(getMaxTransactionsPerSync()).toBe(500);
    });

    it('should return 500 for zero', () => {
      process.env.MAX_TRANSACTIONS_PER_SYNC = '0';
      expect(getMaxTransactionsPerSync()).toBe(500);
    });

    it('should return 500 for negative values', () => {
      process.env.MAX_TRANSACTIONS_PER_SYNC = '-100';
      expect(getMaxTransactionsPerSync()).toBe(500);
    });

    it('should handle float values by parsing as integer', () => {
      process.env.MAX_TRANSACTIONS_PER_SYNC = '750.5';
      expect(getMaxTransactionsPerSync()).toBe(750);
    });
  });
});
