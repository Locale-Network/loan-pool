import createClient from "openapi-fetch";
import { components, paths } from "./schema";
import { calculateRequiredInterestRate, Transaction } from "./debt";
import { stringToHex } from "viem";
import Decimal from "decimal.js";

const MAX_LOAN_AMOUNT = BigInt("1000000000000000000"); // 1 quintillion (1e18)
const MIN_LOAN_AMOUNT = BigInt(1);

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
  try {
    // Decode hex-encoded payload to UTF-8 string
    const payloadStr =
      data.payload &&
      Buffer.from(data.payload.slice(2), "hex").toString("utf8");

    const payload = payloadStr ? JSON.parse(payloadStr) : null;
    const loanId: string | undefined =
      payload?.loanId;
    if (!loanId) {
      throw new Error("Loan ID is required");
    }

     const loanAmountStr: string | undefined = payload?.loanAmount;
    if (!loanAmountStr) {
      throw new Error("Loan amount missing");
    }


        // Validate and convert loan amount using BigInt
    let loanAmountBigInt: bigint;
    try {
      loanAmountBigInt = BigInt(loanAmountStr);
    } catch (e) {
      throw new Error("Invalid loan amount format");
    }


        // Validate loan amount range
    if (loanAmountBigInt <= MIN_LOAN_AMOUNT) {
      throw new Error("Loan amount must be greater than 0");
    }
    if (loanAmountBigInt >= MAX_LOAN_AMOUNT) {
      throw new Error("Loan amount exceeds maximum allowed");
    }
     // Convert BigInt to Decimal for precise calculations
    const loanAmountDecimal = new Decimal(loanAmountBigInt.toString());


    const transactions: Transaction[] | undefined =
      payload?.transactions;

    if (!transactions) {
      throw new Error("Transactions are required");
    }

    const interestRate = calculateRequiredInterestRate(
      transactions,
      loanAmountDecimal.toNumber()
    );

     const response = {
      loanId,
      interestRate: new Decimal(interestRate).toFixed(6),
      loanAmount: loanAmountBigInt.toString()
    };

    await fetch(`${rollupServer}/notice`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
       body: JSON.stringify({ 
        payload: stringToHex(JSON.stringify(response))
      }),
    });
  } catch (e) {
    console.log("Error processing advance request", e);
    throw e; // Re-throw to ensure errors are properly handled
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
