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
  cpus: number | null;
  memoryGb: number | null;
  diskGb: number | null;
  zone: string;
  project: string;
  ip: string | null;
  internalIp: string | null;
  cpuPlatform: string | null;
  createdAt: string | null;
  lastStart: string | null;
  lastStop: string | null;
  lastSuspend: string | null;
  hourly: number | null;
  suspendedDaily: number | null;
  rdpPort: number;
};

type Instance = {
  name: string;
  status: string;
  machineType: string;
  zone: string;
  cpuPlatform?: string;
  creationTimestamp?: string;
  disks?: { boot?: boolean; diskSizeGb?: string }[];
  networkInterfaces?: { networkIP?: string; accessConfigs?: { natIP?: string }[] }[];
  lastStartTimestamp?: string;
  lastStopTimestamp?: string;
  lastSuspendedTimestamp?: string;
};

// vCPU / RAM (GB) of the predefined types we're likely to use; reading machineTypes would need another permission.
const SHAPES: Record<string, [number, number]> = {
  "e2-medium": [2, 4],
  "e2-standard-2": [2, 8],
  "e2-standard-4": [4, 16],
  "e2-standard-8": [8, 32],
  "e2-highmem-2": [2, 16],
  "e2-highmem-4": [4, 32],
  "n2-standard-2": [2, 8],
  "n2-standard-4": [4, 16],
  "n2-highmem-2": [2, 16],
  "n2d-standard-2": [2, 8],
  "n2d-standard-4": [4, 16],
  "n2d-standard-8": [8, 32],
  "t2d-standard-4": [4, 16],
  "t2d-standard-8": [8, 32],
  "c3d-standard-4": [4, 16],
  "c3d-standard-8": [8, 32],
};

// europe-west1 on-demand USD per vCPU-hour and per GB-hour (Cloud Billing Catalog, Oct 2026).
const RATES: Record<string, [number, number]> = {
  e2: [0.02399, 0.00322],
  n2: [0.03477, 0.00466],
  n2d: [0.03025, 0.00405],
  t2d: [0.03025, 0.00405],
  c3d: [0.03255, 0.00436],
};
const WINDOWS_PER_VCPU = 0.046;
const IP_AND_TRAFFIC = 0.01; // static-ish extras per running hour
const DISK_PER_GB_MONTH = 0.1; // pd-balanced
const SAVED_RAM_PER_GB_MONTH = 0.17; // memory kept while suspended

function costs(machineType: string, diskGb: number | null) {
  const shape = SHAPES[machineType];
  const rate = RATES[machineType.split("-")[0]];
  const disk = ((diskGb ?? 0) * DISK_PER_GB_MONTH) / 730;
  if (!shape || !rate) return { hourly: null, suspendedDaily: null };
  const [cpus, gb] = shape;
  return {
    hourly: cpus * (rate[0] + WINDOWS_PER_VCPU) + gb * rate[1] + IP_AND_TRAFFIC + disk,
    suspendedDaily: (gb * SAVED_RAM_PER_GB_MONTH * 24) / 730 + disk * 24,
  };
}

export async function getVm(): Promise<VmStatus> {
  const c = await auth();
  const { data } = await c.request<Instance>({ url: instanceUrl() });
  const machineType = data.machineType.split("/").pop() ?? data.machineType;
  const boot = data.disks?.find((d) => d.boot) ?? data.disks?.[0];
  const nic = data.networkInterfaces?.[0];
  const diskGb = boot?.diskSizeGb ? Number(boot.diskSizeGb) : null;
  const rdpPort = data.status === "RUNNING" ? await reportedRdpPort(c) : DEFAULT_RDP_PORT;
  return {
    name: data.name,
    status: data.status,
    machineType,
    cpus: SHAPES[machineType]?.[0] ?? null,
    memoryGb: SHAPES[machineType]?.[1] ?? null,
    diskGb,
    zone: data.zone.split("/").pop() ?? data.zone,
    project: env("GCP_PROJECT_ID"),
    ip: nic?.accessConfigs?.[0]?.natIP ?? null,
    internalIp: nic?.networkIP ?? null,
    cpuPlatform: data.cpuPlatform ?? null,
    createdAt: data.creationTimestamp ?? null,
    lastStart: data.lastStartTimestamp ?? null,
    lastStop: data.lastStopTimestamp ?? null,
    lastSuspend: data.lastSuspendedTimestamp ?? null,
    ...costs(machineType, diskGb),
    rdpPort,
  };
}

const DEFAULT_RDP_PORT = Number(process.env.RDP_PORT ?? 3389);

// The port Windows actually listens on, as reported at boot by vm/startup.ps1 (guest attribute rdp/port).
async function reportedRdpPort(c: AuthClient): Promise<number> {
  try {
    const { data } = await c.request<{ queryValue?: { items?: { key: string; value: string }[] } }>({
      url: `${instanceUrl()}/getGuestAttributes?queryPath=rdp/`,
    });
    const port = Number(data.queryValue?.items?.find((i) => i.key === "port")?.value);
    return Number.isInteger(port) && port > 0 ? port : DEFAULT_RDP_PORT;
  } catch {
    return DEFAULT_RDP_PORT;
  }
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

// Asks the VM to unlock locked-out Windows accounts: vm/unlock-watcher.ps1 long-polls the
// `rdp-unlock` metadata key and unlocks every locked local account when its value changes.
export async function requestUnlock(): Promise<{ requested: string }> {
  type Metadata = { metadata: { fingerprint: string; items?: { key: string; value: string }[] } };
  const c = await auth();
  const { data } = await c.request<Metadata>({ url: instanceUrl() });
  const requested = new Date().toISOString();
  const items = (data.metadata.items ?? []).filter((i) => i.key !== "rdp-unlock");
  await c.request({
    url: `${instanceUrl()}/setMetadata`,
    method: "POST",
    data: { fingerprint: data.metadata.fingerprint, items: [...items, { key: "rdp-unlock", value: requested }] },
  });
  // setMetadata is asynchronous and can still fail (e.g. permissions), so confirm the value landed.
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    const { data: now } = await c.request<Metadata>({ url: instanceUrl() });
    if (now.metadata.items?.some((m) => m.key === "rdp-unlock" && m.value === requested)) return { requested };
  }
  throw new Error("The unlock request did not reach the VM. Try again.");
}

// Turns a Google API error into a short human-readable message.
export function gcpErrorMessage(err: unknown): string {
  const e = err as { response?: { data?: { error?: { message?: string } } }; message?: string };
  return e.response?.data?.error?.message ?? e.message ?? "Unknown error";
}
