import createClient from "openapi-fetch";
import { components, paths } from "./schema";
import { calculateRequiredInterestRate, Transaction } from "./debt";

type AdvanceRequestData = components["schemas"]["Advance"];
type InspectRequestData = components["schemas"]["Inspect"];
type RequestHandlerResult = components["schemas"]["Finish"]["status"];
type RollupsRequest = components["schemas"]["RollupRequest"];
type InspectRequestHandler = (data: InspectRequestData) => Promise<void>;
type AdvanceRequestHandler = (
  data: AdvanceRequestData
) => Promise<RequestHandlerResult>;

const rollupServer = process.env.ROLLUP_HTTP_SERVER_URL;
console.log("HTTP rollup_server url is " + rollupServer);

const handleAdvance: AdvanceRequestHandler = async (data) => {
  console.log("Received advance request data " + JSON.stringify(data));

  try {
    // Decode hex-encoded payload to UTF-8 string
    const payloadStr =
      data.payload &&
      Buffer.from(data.payload.slice(2), "hex").toString("utf8");
    console.log("payloadStr", payloadStr);
    const payload = payloadStr ? JSON.parse(payloadStr) : null;
    const loanId: string | undefined =
      payload?.extractedParameters?.URL_PARAMS_1;
    if (!loanId) {
      throw new Error("Loan ID is required");
    }

    const loanAmount = 12000; // TODO: fetch from contract

    const rawTransactions: string | undefined =
      payload?.extractedParameters?.transactions;

    if (!rawTransactions) {
      throw new Error("Transactions are required");
    }

    const transactions = JSON.parse(rawTransactions) as Transaction[];

    const interestRate = calculateRequiredInterestRate(
      transactions,
      loanAmount
    );

    console.log("Interest rate is " + interestRate);
  } catch (e) {
    console.log("Error processing advance request", e);
  }

  return "accept";
};

const handleInspect: InspectRequestHandler = async (data) => {
  console.log("Received inspect request data " + JSON.stringify(data));
};

const main = async () => {
  const { POST } = createClient<paths>({ baseUrl: rollupServer });
  let status: RequestHandlerResult = "accept";
  while (true) {
    const { response } = await POST("/finish", {
      body: { status },
      parseAs: "text",
    });

    if (response.status === 200) {
      const data = (await response.json()) as RollupsRequest;
      switch (data.request_type) {
        case "advance_state":
          status = await handleAdvance(data.data as AdvanceRequestData);
          break;
        case "inspect_state":
          await handleInspect(data.data as InspectRequestData);
          break;
      }
    } else if (response.status === 202) {
      console.log(await response.text());
    }
  }
};

main().catch((e) => {
  console.log(e);
  process.exit(1);
});
