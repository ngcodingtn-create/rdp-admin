import "server-only";
import { getVercelOidcToken } from "@vercel/oidc";
import { ExternalAccountClient, GoogleAuth, type AuthClient } from "google-auth-library";

// Two ways to authenticate to Google Cloud:
//  1. Vercel OIDC -> Workload Identity Federation (no stored key) when GCP_WORKLOAD_IDENTITY_POOL_ID is set.
//  2. A service-account JSON key, base64-encoded in GCP_SA_KEY_B64 (simplest; fine for local dev).

const env = (name: string) => {
  const v = process.env[name];
  if (!v) throw new Error(`Missing environment variable ${name}`);
  return v;
};

let client: AuthClient | undefined;

async function auth(): Promise<AuthClient> {
  if (client) return client;

  if (process.env.GCP_WORKLOAD_IDENTITY_POOL_ID) {
    const num = env("GCP_PROJECT_NUMBER");
    const pool = env("GCP_WORKLOAD_IDENTITY_POOL_ID");
    const provider = env("GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID");
    const sa = env("GCP_SERVICE_ACCOUNT_EMAIL");
    const wif = ExternalAccountClient.fromJSON({
      type: "external_account",
      audience: `//iam.googleapis.com/projects/${num}/locations/global/workloadIdentityPools/${pool}/providers/${provider}`,
      subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
      token_url: "https://sts.googleapis.com/v1/token",
      service_account_impersonation_url: `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${sa}:generateAccessToken`,
      // Read per request: the Vercel OIDC token is only available inside a request.
      subject_token_supplier: { getSubjectToken: () => getVercelOidcToken() },
    });
    if (!wif) throw new Error("Could not build the Workload Identity client");
    client = wif;
    return client;
  }

  const credentials = JSON.parse(Buffer.from(env("GCP_SA_KEY_B64"), "base64").toString("utf8"));
  client = await new GoogleAuth({
    credentials,
    scopes: ["https://www.googleapis.com/auth/cloud-platform"],
  }).getClient();
  return client;
}

const instanceUrl = () =>
  `https://compute.googleapis.com/compute/v1/projects/${env("GCP_PROJECT_ID")}/zones/${env(
    "GCE_ZONE",
  )}/instances/${env("GCE_INSTANCE")}`;

export type Action = "start" | "stop" | "suspend" | "resume";
export const ACTIONS: readonly Action[] = ["start", "stop", "suspend", "resume"];

export type VmStatus = {
  name: string;
  status: string;
  machineType: string;
  ip: string | null;
  lastStart: string | null;
  lastStop: string | null;
  lastSuspend: string | null;
};

type Instance = {
  name: string;
  status: string;
  machineType: string;
  networkInterfaces?: { accessConfigs?: { natIP?: string }[] }[];
  lastStartTimestamp?: string;
  lastStopTimestamp?: string;
  lastSuspendedTimestamp?: string;
};

export async function getVm(): Promise<VmStatus> {
  const c = await auth();
  const { data } = await c.request<Instance>({ url: instanceUrl() });
  return {
    name: data.name,
    status: data.status,
    machineType: data.machineType.split("/").pop() ?? data.machineType,
    ip: data.networkInterfaces?.[0]?.accessConfigs?.[0]?.natIP ?? null,
    lastStart: data.lastStartTimestamp ?? null,
    lastStop: data.lastStopTimestamp ?? null,
    lastSuspend: data.lastSuspendedTimestamp ?? null,
  };
}

// Fire and forget: Compute Engine returns an Operation immediately; the UI polls getVm().
export async function runAction(action: Action): Promise<{ operation: string }> {
  const c = await auth();
  const { data } = await c.request<{ name: string }>({
    url: `${instanceUrl()}/${action}`,
    method: "POST",
  });
  return { operation: data.name };
}

// Turns a Google API error into a short human-readable message.
export function gcpErrorMessage(err: unknown): string {
  const e = err as { response?: { data?: { error?: { message?: string } } }; message?: string };
  return e.response?.data?.error?.message ?? e.message ?? "Unknown error";
}
