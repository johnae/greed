//! Signing in: what a server offers, and the steps of each way.

use std::collections::HashMap;

use greed_chat::protocol::{Field, Method, Step};
use greed_chat::random;
use greed_chat::rpc::Failure;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::api::Api;
use crate::{Mattermost, Signed};

/// A sign-in going on.
pub(crate) struct Login {
    api: Api,
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

#[derive(Deserialize)]
pub(crate) struct Start {
    server: String,
    method: Method,
}

#[derive(Deserialize)]
pub(crate) struct Answer {
    login: String,
    values: HashMap<String, String>,
}

#[derive(Deserialize)]
pub(crate) struct Cancel {
    login: String,
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

impl Mattermost {
    /// Starts signing in to `server` with `method`: `{login, step}`.
    pub(crate) fn start(&self, start: &Start) -> Result<Value, Failure> {
        if start.method != Method::Password {
            return Err(Failure::new("only passwords for now"));
        }
        let api = Api::new(&start.server).map_err(Failure::new)?;
        let id = random(8);
        self.logins.borrow_mut().insert(id.clone(), Login { api });
        Ok(json!({ "login": id, "step": password_fields(false, None) }))
    }

    /// The step after `answer`'s values.
    pub(crate) async fn answer(&self, answer: Answer) -> Result<Value, Failure> {
        let api = self
            .logins
            .borrow()
            .get(&answer.login)
            .map(|login| login.api.clone())
            .ok_or_else(|| Failure::new("that sign-in is over"))?;
        let value = |name: &str| answer.values.get(name).map_or("", String::as_str);
        let body = json!({
            "login_id": value("user"),
            "password": value("password"),
            "token": value("code"),
        });
        let (token, user) = match api.login("api/v4/users/login", &body).await {
            Ok(signed) => signed,
            Err(e) => {
                let code = answer.values.contains_key("code") || e.id.contains("mfa");
                return Ok(json!(password_fields(code, Some(e.message))));
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
    pub(crate) fn cancel(&self, cancel: &Cancel) {
        self.logins.borrow_mut().remove(&cancel.login);
    }
}
