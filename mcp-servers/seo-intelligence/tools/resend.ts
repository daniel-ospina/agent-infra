import { Resend } from "resend";

function getClient(): Resend {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) throw new Error("RESEND_API_KEY not configured");
  return new Resend(apiKey);
}

function getDefaultFrom(): string {
  return process.env.RESEND_FROM_EMAIL ?? "onboarding@resend.dev";
}

export async function sendEmail(params: {
  to: string[];
  subject: string;
  html?: string;
  text?: string;
  from?: string;
  reply_to?: string;
  cc?: string[];
  bcc?: string[];
}) {
  const resend = getClient();

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data, error } = await (resend.emails.send as any)({
    from: params.from ?? getDefaultFrom(),
    to: params.to,
    subject: params.subject,
    html: params.html,
    text: params.text,
    replyTo: params.reply_to,
    cc: params.cc,
    bcc: params.bcc,
  });

  if (error) throw new Error(`Resend error: ${error.message}`);
  return data;
}

export async function getEmail(emailId: string) {
  const resend = getClient();
  const { data, error } = await resend.emails.get(emailId);
  if (error) throw new Error(`Resend error: ${error.message}`);
  return data;
}
