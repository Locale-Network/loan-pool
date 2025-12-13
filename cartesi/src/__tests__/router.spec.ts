import { Router, isAuthorizedSender, addAuthorizedSender, removeAuthorizedSender, clearAuthorizedSenders } from '../router';

// Mock fetch
global.fetch = jest.fn(() =>
  Promise.resolve({
    ok: true,
    json: () => Promise.resolve({}),
  })
) as jest.Mock;

describe('Router Module', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    // Clear whitelist between tests
    clearAuthorizedSenders();
  });

  describe('Authorization', () => {
    it('should allow all senders when whitelist is empty (development mode)', () => {
      expect(isAuthorizedSender('0xrandomaddress')).toBe(true);
    });

    it('should allow whitelisted senders', () => {
      addAuthorizedSender('0x1234567890abcdef1234567890abcdef12345678');

      expect(
        isAuthorizedSender('0x1234567890abcdef1234567890abcdef12345678')
      ).toBe(true);
    });

    it('should reject non-whitelisted senders when whitelist has entries', () => {
      addAuthorizedSender('0x1234567890abcdef1234567890abcdef12345678');

      expect(
        isAuthorizedSender('0xdeadbeef00000000000000000000000000000000')
      ).toBe(false);
    });

    it('should handle case-insensitive addresses', () => {
      addAuthorizedSender('0xABCDEF1234567890ABCDEF1234567890ABCDEF12');

      expect(
        isAuthorizedSender('0xabcdef1234567890abcdef1234567890abcdef12')
      ).toBe(true);
    });

    it('should remove sender from whitelist', () => {
      addAuthorizedSender('0x1234567890abcdef1234567890abcdef12345678');
      removeAuthorizedSender('0x1234567890abcdef1234567890abcdef12345678');
      addAuthorizedSender('0xdeadbeef00000000000000000000000000000000');

      expect(
        isAuthorizedSender('0x1234567890abcdef1234567890abcdef12345678')
      ).toBe(false);
    });
  });

  describe('Router', () => {
    let router: Router;

    beforeEach(() => {
      router = new Router();
    });

    it('should register and call advance handlers', async () => {
      const mockHandler = jest.fn().mockResolvedValue({
        status: 'accept',
        response: { success: true },
      });

      router.registerAdvanceHandler('test_action', mockHandler);

      const payload = JSON.stringify({ action: 'test_action', data: 'test' });
      const hexPayload = '0x' + Buffer.from(payload).toString('hex');

      const result = await router.handleAdvance({
        metadata: {
          msg_sender: '0xsender',
          epoch_index: 0,
          input_index: 0,
          block_number: 0,
          timestamp: 0,
        },
        payload: hexPayload,
      });

      expect(mockHandler).toHaveBeenCalled();
      expect(result).toBe('accept');
    });

    it('should reject unknown actions', async () => {
      const payload = JSON.stringify({ action: 'unknown_action' });
      const hexPayload = '0x' + Buffer.from(payload).toString('hex');

      const result = await router.handleAdvance({
        metadata: {
          msg_sender: '0xsender',
          epoch_index: 0,
          input_index: 0,
          block_number: 0,
          timestamp: 0,
        },
        payload: hexPayload,
      });

      expect(result).toBe('reject');
    });

    it('should reject requests without action', async () => {
      const payload = JSON.stringify({ data: 'no action' });
      const hexPayload = '0x' + Buffer.from(payload).toString('hex');

      const result = await router.handleAdvance({
        metadata: {
          msg_sender: '0xsender',
          epoch_index: 0,
          input_index: 0,
          block_number: 0,
          timestamp: 0,
        },
        payload: hexPayload,
      });

      expect(result).toBe('reject');
    });

    it('should reject requests with invalid JSON', async () => {
      const hexPayload = '0x' + Buffer.from('invalid json {').toString('hex');

      const result = await router.handleAdvance({
        metadata: {
          msg_sender: '0xsender',
          epoch_index: 0,
          input_index: 0,
          block_number: 0,
          timestamp: 0,
        },
        payload: hexPayload,
      });

      expect(result).toBe('reject');
    });

    it('should register and call inspect handlers', async () => {
      const mockHandler = jest.fn().mockResolvedValue({ data: 'result' });

      router.registerInspectHandler('test_query', mockHandler);

      const payload = JSON.stringify({ type: 'test_query', params: { id: '123' } });
      const hexPayload = '0x' + Buffer.from(payload).toString('hex');

      await router.handleInspect({
        payload: hexPayload,
      });

      expect(mockHandler).toHaveBeenCalledWith({
        type: 'test_query',
        params: { id: '123' },
      });
    });

    it('should parse path-format inspect queries', async () => {
      const mockHandler = jest.fn().mockResolvedValue({ data: 'result' });

      router.registerInspectHandler('loan', mockHandler);

      const payload = 'loan/id/loan-001';
      const hexPayload = '0x' + Buffer.from(payload).toString('hex');

      await router.handleInspect({
        payload: hexPayload,
      });

      expect(mockHandler).toHaveBeenCalledWith({
        type: 'loan',
        params: { id: 'loan-001' },
      });
    });

    it('should handle inspect query with single param', async () => {
      const mockHandler = jest.fn().mockResolvedValue({ data: 'result' });

      router.registerInspectHandler('borrower', mockHandler);

      const payload = 'borrower/0x1234';
      const hexPayload = '0x' + Buffer.from(payload).toString('hex');

      await router.handleInspect({
        payload: hexPayload,
      });

      expect(mockHandler).toHaveBeenCalledWith({
        type: 'borrower',
        params: { id: '0x1234' },
      });
    });

    it('should reject unauthorized senders when whitelist is active', async () => {
      addAuthorizedSender('0xauthorized');

      const payload = JSON.stringify({ action: 'test_action' });
      const hexPayload = '0x' + Buffer.from(payload).toString('hex');

      const result = await router.handleAdvance({
        metadata: {
          msg_sender: '0xunauthorized',
          epoch_index: 0,
          input_index: 0,
          block_number: 0,
          timestamp: 0,
        },
        payload: hexPayload,
      });

      expect(result).toBe('reject');
    });
  });
});
