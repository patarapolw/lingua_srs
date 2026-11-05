export interface Env {
  DB: D1Database;
  /** Address confirmation emails come from, e.g. "LinguaSRS <noreply@example.com>". */
  MAIL_FROM: string;
  /** Secret. Without it no email is sent (unless DEV_LOG_EMAILS is "true"). */
  RESEND_API_KEY?: string;
  /** Local development only: print emails to the console instead. */
  DEV_LOG_EMAILS?: string;
  /** Confirmation emails per UTC day, across all accounts. Default 50. */
  MAX_EMAILS_PER_DAY?: string;
  /** Records written per account per UTC day. Default 2000. */
  MAX_WRITES_PER_DAY?: string;
}

export interface Mail {
  to: string;
  subject: string;
  text: string;
  html: string;
}

/** Things the handler needs from outside, so tests can replace them. */
export interface Deps {
  sendMail(mail: Mail): Promise<void>;
  now(): number;
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(code);
  }
}
