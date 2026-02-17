# Discourse Login Helper — Plugin Overview

## Purpose

`discourse-login-helper` simplifies the login experience for non-technical or mass-subscribed users. It reduces friction by automatically initiating a magic-link login when a user follows a forum link from an email notification, without requiring any manual interaction on a login form.

## Core Concept

When Discourse sends notification emails to users, this plugin enriches every forum link in those emails by appending a `?login=<email>` query parameter. When the recipient clicks such a link without being logged in, the plugin intercepts the request and immediately dispatches a one-click login email — sending the user directly back to the originally linked page after authentication.

---

## User Flow

```
Discourse sends notification email
        │
        ▼
Links contain ?login=<user-email>
        │
        ▼
User clicks link (not logged in)
        │
        ▼
Plugin intercepts request
        │
        ├─ No recent token (or force=1) ──► Send magic login email
        │                                          │
        │                                          ▼
        │                               Confirmation page shown
        │                               ("Check your inbox")
        │
        └─ Token sent within last 20 min ─► "Already sent" page shown
                                                   │
                                          "Send new link" button
                                          (triggers resend with force=1)
        │
        ▼
User clicks magic link in email
        │
        ▼
User is logged in and redirected to the original destination URL
```

---

## Components

### Backend (`plugin.rb`)

All logic lives in a single `plugin.rb` file, split across several modules and controller extensions.

#### `LoginHelperController`

A lightweight Rails controller mounted at `/login-helper`:

| Endpoint | Method | Purpose |
|---|---|---|
| `/login-helper/send-login-mail` | `GET` | Sends the magic login email and renders a confirmation page |
| `/login-helper/redirect-to-login` | `POST` | Sets cookies (`email`, `destination_url`) and redirects to `/login` |

The `send_login_mail` action:
- Requires `enable_local_logins_via_email` and `login_helper_enabled` to be active.
- Redirects already-logged-in users to the homepage.
- Applies IP-based rate limiting (6/hour, 3/minute) on every request.
- **Already-sent check**: If a non-confirmed `EmailToken` with scope `email_login` exists for this user within the last 20 minutes, no new email is sent and `@already_sent = true` is set. The user-level rate limiter is not consumed in this case.
  - This check is bypassed when `params[:force]` is present (used by the "Send new link" button).
- If sending: applies user-level rate limiting, creates an `EmailToken` with `scope: :email_login` storing the `destination_url`, and enqueues a `critical_user_email` job.
- Renders `send_login_mail.html.erb` using the `no_ember` layout, passing the `@already_sent` flag.

#### `LoginHelper::MessageBuilderExtension`

Prepended to `Email::MessageBuilder`. Intercepts all outgoing emails and rewrites forum links in both:
- **HTML emails**: Parses the HTML with Nokogiri and appends `?login=<recipient>` to all `<a href>` attributes pointing to the forum.
- **Plain text emails**: Uses a regex to find and rewrite bare URLs.

Only links pointing to the same Discourse instance (matched by hostname) and targeting `/c/` (categories) or `/t/` (topics) are modified.

#### `LoginHelper::ApplicationControllerExtension`

Prepended to `ApplicationController`. Intercepts two scenarios where a user is not logged in:

1. **`redirect_to_login_if_required`**: If `params[:login]` is present, redirects to the `send-login-mail` endpoint instead of the default login page.
2. **`rescue_discourse_actions`**: If an `invalid_access` error occurs and `params[:login]` is present, same redirect applies — covers cases like private categories where access is denied.

#### `LoginHelper::SessionControllerExtension`

Prepended to `SessionController`. Overrides `email_login` to include `destination_url` from the confirmed `EmailToken` in the JSON response, so the frontend can redirect to the correct page.

#### `email_renderer_html` modifier

Registered via `plugin.register_modifier`. Rewrites links in HTML emails using Discourse's newer email renderer hook, complementing the `MessageBuilderExtension`.

#### `LoginHelper` module helpers

```ruby
LoginHelper.add_user_to_forum_links(link, username)
```
Parses a URL, checks if it points to this forum, and appends `?login=<username>` if it targets a category or topic path. Handles Unicode URLs safely via percent-encoding.

---

### Frontend (`login_helper.js`)

Reopens the `EmailLoginController` to override the `finishLogin` action. After a successful magic-link login, instead of always redirecting to `/`, it reads `result.destination_url` from the server response and redirects there. Safe mode query parameters are preserved.

---

### Database Migration

```
db/migrate/20240527210056_add_destination_url_to_email_token.rb
```

Adds a `destination_url` string column to the `email_tokens` table. This stores the original URL a user was trying to access when the login flow was triggered, enabling the post-login redirect.

---

### View (`send_login_mail.html.erb`)

A minimal confirmation page rendered with the `no_ember` layout (no Ember.js SPA overhead). It handles two states:

**Normal (email just sent):**
- Site title and description
- Confirmation that a login email was sent to the user's address
- Advice to check the spam folder

**Already sent (token within last 20 minutes):**
- Notice that a link was already sent recently
- "Send a new login link" button — links to the same endpoint with `force=1`

Both states always show:
- Contact information (from `SiteSetting.contact_email`)
- A fallback button: "Show other login options" — submits to `redirect-to-login`, which sets cookies and opens the standard Discourse `/login` page

---

## Site Settings

| Setting | Default | Description |
|---|---|---|
| `login_helper_enabled` | `true` | Enables or disables the entire plugin |

The plugin also requires `enable_local_logins_via_email` (a core Discourse setting) to be active for the `send-login-mail` endpoint to function.

---

## Localization

Supported languages: **English** (`server.en.yml`) and **German** (`server.de.yml`).

Translated keys:
- `login_helper.mail_sent_to` — confirmation message with recipient address
- `login_helper.click_link` — instruction to click the emailed link
- `login_helper.search_spam` — spam folder reminder
- `login_helper.already_sent` — notice that a login link was already sent recently (includes `%{to}`)
- `login_helper.request_new_link` — "send new link" button label
- `login_helper.contact_info` — contact link with `contact_email` setting
- `login_helper.redirect_to_login_page` — fallback button label

---

## Security Considerations

- **Rate limiting**: Multiple rate limiters per IP and per user (6/hour, 3/minute) protect against abuse of the login-mail endpoint.
- **User presence check**: Only real, non-staged users trigger an actual email; the response is always identical regardless of whether an account was found (no user enumeration).
- **No auto-authentication**: The plugin does not log users in automatically — it still requires the user to click the magic link.
- **Cookie scope**: The `email` and `destination_url` cookies set by `redirect-to-login` expire after 1 hour.
- **Link scope**: Only `/c/` and `/t/` paths on the same domain are enriched; other links (external, admin, API) are not modified.

---

## File Structure

```
plugins/discourse-login-helper/
├── plugin.rb                          # All backend logic (controller, extensions, helpers)
├── config/
│   ├── settings.yml                   # login_helper_enabled site setting
│   └── locales/
│       ├── server.en.yml              # English translations
│       └── server.de.yml              # German translations
├── app/
│   └── views/
│       └── send_login_mail.html.erb   # Confirmation page after magic email is sent
├── assets/
│   └── javascripts/discourse/
│       └── initializers/
│           └── login_helper.js        # Frontend: redirect to destination_url after login
└── db/
    └── migrate/
        └── 20240527210056_add_destination_url_to_email_token.rb
```

---

## Version History

| Version | Changes |
|---|---|
| 0.12 | Skip resending login email if a valid token was sent within the last 20 minutes; show "already sent" notice with explicit resend button |
| 0.11 | Previous version |
| 0.6 | Send login link on all pages when `login` parameter is present |
| 0.5 | Fix handling of links with Unicode characters; improved disable handling |
| 0.4 | Store `destination_url` in email tokens and redirect after login |
| 0.3 | Enrich all Discourse notification links with user information |
