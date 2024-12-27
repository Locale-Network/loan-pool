export interface ProofContext {
  contextAddress: string;
  contextMessage: string;
  extractedParameters: Record<string, string>;
  providerHash: string;
}
