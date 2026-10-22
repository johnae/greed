//! Signing in: what a server offers, and the steps of each way.

use std::collections::HashMap;

use greed_chat::loopback;
use greed_chat::protocol::{Answer, Field, LoginParams, Method, Start, Step};
use greed_chat::random;
use greed_chat::rpc::Failure;
use serde_json::{Value, json};

use crate::api::Api;
use crate::{Mattermost, Signed};

/// A sign-in going on.
pub(crate) struct Login {
    api: Api,
    way: Way,
}

#[derive(Clone)]
enum Way {
    Password,
    /// Through the browser, as Mattermost's desktop app does: the server
    /// sends the browser back with our `client_token` and a token of its
    /// own to sign in with.
    Browser {
        client_token: String,
    },
}

/// The browser sign-ins Mattermost has: the client config's switch, the
/// service's id in `/oauth/{id}/login`, the config holding the button's
/// text, and the name to show without one.
const BROWSER: &[(&str, &str, &str, &str)] = &[
    (
        "EnableSignUpWithOpenId",
        "openid",
        "OpenIdButtonText",
        "OpenID",
    ),
    (
        "EnableSignUpWithGitLab",
        "gitlab",
        "GitLabButtonText",
        "GitLab",
    ),
    ("EnableSignUpWithGoogle", "google", "", "Google"),
    ("EnableSignUpWithOffice365", "office365", "", "Microsoft"),
    ("EnableSaml", "saml", "SamlLoginButtonText", "SAML"),
];

/// The ways `server` offers to sign in, the browser's first.
pub(crate) async fn methods(server: &str) -> Result<Vec<Method>, Failure> {
    let api = Api::new(server).map_err(Failure::new)?;
    let config: HashMap<String, String> = api
        .get("api/v4/config/client?format=old")
        .await
        .map_err(|e| Failure::new(format!("can't reach {}: {e}", api.address())))?;
    let on = |key: &str| config.get(key).is_some_and(|value| value == "true");
    let mut methods: Vec<Method> = BROWSER
        .iter()
        .filter(|(switch, ..)| on(switch))
        .map(|(_, id, text, name)| Method::Browser {
            id: (*id).into(),
            name: config
                .get(*text)
                .filter(|text| !text.is_empty())
                .map_or_else(|| (*name).into(), Clone::clone),
        })
        .collect();
    if on("EnableSignInWithEmail") || on("EnableSignInWithUsername") {
        methods.push(Method::Password);
    }
    Ok(methods)
}

/// Asks for a name and password, and the code from an authenticator app
/// when `code` (multi-factor authentication is on for the account).
fn password_fields(code: bool, why: Option<String>) -> Step {
    let mut fields = vec![
        Field::text("user", "Email or username"),
        Field::secret("password", "Password"),
    ];
    if code {
        fields.push(Field::text("code", "Code from your authenticator app"));
    }
    Step::Ask { fields, why }
}

/// What the browser sign-in says to paste where the browser can't hand its
/// link to Greed by itself.
const PASTE: &str = "the link the browser ends on: mattermost://… (or …/login/desktop?…)";

/// Where `api`'s server sends the browser for `service`, and on to its
/// sign-in page, with `client_token` to know the answer by.
fn browser_url(api: &Api, service: &str, client_token: &str) -> String {
    let path = if service == "saml" {
        "login/sso/saml".to_string()
    } else {
        format!("oauth/{service}/login")
    };
    format!("{}/{path}?desktop_token={client_token}", api.address())
}

impl Mattermost {
    /// Starts signing in to `server` with `method`: `{login, step}`.
    pub(crate) fn start(&self, start: &Start) -> Result<Value, Failure> {
        let api = Api::new(&start.server).map_err(Failure::new)?;
        let (way, step) = match &start.method {
            Method::Password => (Way::Password, password_fields(false, None)),
            Method::Browser { id, .. } => {
                let client_token = random(16);
                let url = browser_url(&api, id, &client_token);
                let step = Step::Open {
                    url,
                    paste: Some(PASTE.into()),
                };
                (Way::Browser { client_token }, step)
            }
            _ => return Err(Failure::new("Mattermost has no such sign-in")),
        };
        let id = random(8);
        self.logins
            .borrow_mut()
            .insert(id.clone(), Login { api, way });
        Ok(json!({ "login": id, "step": step }))
    }

    /// The step after `answer`'s values: a name and password, or the link
    /// the browser ended on (`link`).
    pub(crate) async fn answer(&self, answer: &Answer) -> Result<Value, Failure> {
        let (api, way) = self
            .logins
            .borrow()
            .get(&answer.login)
            .map(|login| (login.api.clone(), login.way.clone()))
            .ok_or_else(|| Failure::new("that sign-in is over"))?;
        let (token, user) = match way {
            Way::Password => {
                let body = json!({
                    "login_id": answer.value("user"),
                    "password": answer.value("password"),
                    "token": answer.value("code"),
                });
                match api.login("api/v4/users/login", &body).await {
                    Ok(signed) => signed,
                    Err(e) => {
                        let code = answer.values.contains_key("code") || e.id.contains("mfa");
                        return Ok(json!(password_fields(code, Some(e.message))));
                    }
                }
            }
            Way::Browser { client_token } => {
                let query = loopback::query(answer.value("link"));
                let (Some(theirs), Some(server_token)) =
                    (query.get("client_token"), query.get("server_token"))
                else {
                    return Err(Failure::new(format!("that isn't the link: paste {PASTE}")));
                };
                if *theirs != client_token {
                    return Err(Failure::new("that link is from another sign-in"));
                }
                let body = json!({ "token": server_token });
                api.login("api/v4/users/login/desktop_token", &body)
                    .await
                    .map_err(|e| Failure::new(format!("the server didn't take it: {e}")))?
            }
        };
        self.logins.borrow_mut().remove(&answer.login);
        let signed = Signed {
            api: api.with_token(token),
            user,
        };
        let secret = signed.secret();
        let account = self.signed_in(signed);
        Ok(json!(Step::Done { account, secret }))
    }

    /// Gives up a sign-in.
    pub(crate) fn cancel(&self, cancel: &LoginParams) {
        self.logins.borrow_mut().remove(&cancel.login);
    }
}
