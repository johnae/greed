//! Calendar invites (iMIP, RFC 6047): the iCalendar part of a message read
//! as an event to show, its times in this machine's time zone, and the
//! REPLY that answers it (RFC 5546), sent to whoever organized it.

use jiff::Timestamp;
use jiff::civil::{Date, DateTime, Time, Weekday};
use jiff::tz::{Offset, TimeZone};
use serde::Serialize;

/// An event as an invite shows it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Invite {
    /// What the invite does: REQUEST (asks), CANCEL, REPLY (an answer to
    /// yours), and so on.
    pub method: String,
    pub summary: String,
    pub location: Option<String>,
    /// When it starts and ends, RFC 3339 in local time, or a date for a
    /// day-long one.
    pub start: Option<String>,
    pub end: Option<String>,
    pub all_day: bool,
    pub organizer: Option<Person>,
    pub attendees: Vec<Person>,
    /// Whether it repeats.
    pub repeats: bool,
    pub cancelled: bool,
    /// Your answer so far (ACCEPTED, TENTATIVE, DECLINED, NEEDS-ACTION), as
    /// the invite has it.
    pub answer: Option<String>,
}

/// Someone an event names.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Person {
    pub name: Option<String>,
    pub address: String,
    /// Their answer, for an attendee.
    pub answer: Option<String>,
}

/// An answer to an invite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    Accepted,
    Tentative,
    Declined,
}

impl Answer {
    pub fn parse(word: &str) -> Option<Answer> {
        match word {
            "accepted" | "accept" | "yes" => Some(Answer::Accepted),
            "tentative" | "maybe" => Some(Answer::Tentative),
            "declined" | "decline" | "no" => Some(Answer::Declined),
            _ => None,
        }
    }

    fn partstat(self) -> &'static str {
        match self {
            Answer::Accepted => "ACCEPTED",
            Answer::Tentative => "TENTATIVE",
            Answer::Declined => "DECLINED",
        }
    }

    fn word(self) -> &'static str {
        match self {
            Answer::Accepted => "Accepted",
            Answer::Tentative => "Tentative",
            Answer::Declined => "Declined",
        }
    }
}

/// A REPLY ready to send: to whom, its subject and text, and the
/// iCalendar it carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    pub to: String,
    pub subject: String,
    pub text: String,
    pub calendar: String,
}

/// A content line: its name, parameters and value, and the line as it was.
#[derive(Debug, Clone)]
struct Line {
    name: String,
    params: Vec<(String, String)>,
    value: String,
    raw: String,
}

impl Line {
    fn param(&self, name: &str) -> Option<&str> {
        self.params
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// A component (VCALENDAR, VEVENT, VTIMEZONE...) and what's in it.
#[derive(Debug, Clone, Default)]
struct Component {
    name: String,
    lines: Vec<Line>,
    children: Vec<Component>,
}

impl Component {
    fn line(&self, name: &str) -> Option<&Line> {
        self.lines.iter().find(|l| l.name == name)
    }

    fn value(&self, name: &str) -> Option<String> {
        self.line(name).map(|l| unescape(&l.value))
    }

    fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Component> + 'a {
        self.children.iter().filter(move |c| c.name == name)
    }

    /// The event the invite is about: the first that isn't one occurrence
    /// of a repeating one, or else the first.
    fn event(&self) -> Option<&Component> {
        self.all("VEVENT")
            .find(|e| e.line("RECURRENCE-ID").is_none())
            .or_else(|| self.all("VEVENT").next())
    }
}

/// The lines of `ics`, unfolded.
fn unfold(ics: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for line in ics.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if let Some(rest) = line.strip_prefix([' ', '\t'])
            && let Some(last) = lines.last_mut()
        {
            last.push_str(rest);
        } else if !line.is_empty() {
            lines.push(line.to_string());
        }
    }
    lines
}

fn parse_line(raw: &str) -> Option<Line> {
    // The value starts at the first colon outside quotes.
    let mut quoted = false;
    let colon = raw.char_indices().find_map(|(i, c)| match c {
        '"' => {
            quoted = !quoted;
            None
        }
        ':' if !quoted => Some(i),
        _ => None,
    })?;
    let (head, value) = (&raw[..colon], &raw[colon + 1..]);
    let mut parts = head.split(';');
    let name = parts.next()?.to_ascii_uppercase();
    let params = parts
        .filter_map(|p| {
            let (n, v) = p.split_once('=')?;
            Some((n.to_ascii_uppercase(), v.trim_matches('"').to_string()))
        })
        .collect();
    Some(Line {
        name,
        params,
        value: value.to_string(),
        raw: raw.to_string(),
    })
}

/// The VCALENDAR in `ics`.
fn parse(ics: &str) -> Option<Component> {
    let mut stack: Vec<Component> = vec![Component::default()];
    for raw in unfold(ics) {
        let Some(line) = parse_line(&raw) else {
            continue;
        };
        match line.name.as_str() {
            "BEGIN" => stack.push(Component {
                name: line.value.to_ascii_uppercase(),
                ..Component::default()
            }),
            "END" if stack.len() > 1 => {
                let done = stack.pop()?;
                stack.last_mut()?.children.push(done);
            }
            _ => stack.last_mut()?.lines.push(line),
        }
    }
    stack
        .into_iter()
        .next()?
        .children
        .into_iter()
        .find(|c| c.name == "VCALENDAR")
}

/// A TEXT value as it reads.
fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n' | 'N') => out.push('\n'),
                Some(other) => out.push(other),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// The address a `mailto:` value names.
fn address(value: &str) -> String {
    let bare = value
        .strip_prefix("mailto:")
        .or_else(|| value.strip_prefix("MAILTO:"))
        .unwrap_or(value);
    bare.trim().to_string()
}

fn person(line: &Line) -> Person {
    Person {
        name: line.param("CN").map(str::to_string),
        address: address(&line.value),
        answer: line.param("PARTSTAT").map(str::to_ascii_uppercase),
    }
}

/// `value` (`20261024T100000`, with `Z` for UTC) as a civil date and time.
fn civil(value: &str) -> Option<(DateTime, bool)> {
    let (value, utc) = match value.strip_suffix('Z') {
        Some(v) => (v, true),
        None => (value, false),
    };
    let (date, time) = value.split_once('T')?;
    let time = Time::new(two(time, 0)?, two(time, 2)?, two(time, 4).unwrap_or(0), 0).ok()?;
    Some((date_of(date)?.to_datetime(time), utc))
}

/// `20261024` as a date.
fn date_of(value: &str) -> Option<Date> {
    let year = value.get(..4)?.parse().ok()?;
    Date::new(year, two(value, 4)?, two(value, 6)?).ok()
}

/// The two-digit number at `at` in `text`.
fn two(text: &str, at: usize) -> Option<i8> {
    text.get(at..at + 2)?.parse().ok()
}

/// A `DTSTART`/`DTEND` line as local time (or a date, and true, for a
/// day-long event). A zone the system doesn't know, like Outlook's
/// Windows names, is read from the invite's own VTIMEZONE.
fn when(line: &Line, calendar: &Component, local: &TimeZone) -> Option<(String, bool)> {
    if line.param("VALUE") == Some("DATE") || !line.value.contains('T') {
        return Some((date_of(&line.value)?.to_string(), true));
    }
    let (dt, utc) = civil(&line.value)?;
    let zone = if utc {
        TimeZone::UTC
    } else if let Some(name) = line.param("TZID") {
        match TimeZone::get(name) {
            Ok(zone) => zone,
            Err(_) => TimeZone::fixed(own_offset(calendar, name, dt)?),
        }
    } else {
        // Floating: the same wall time wherever you are.
        local.clone()
    };
    let at = zone.to_zoned(dt).ok()?.with_time_zone(local.clone());
    Some((at.strftime("%Y-%m-%dT%H:%M:%S%:z").to_string(), false))
}

/// The offset the invite's VTIMEZONE `name` has at `dt`: its STANDARD or
/// DAYLIGHT part, whichever last began by then, each beginning on its
/// DTSTART's day and time, or yearly as its RRULE says (BYMONTH and a
/// BYDAY like `-1SU`).
fn own_offset(calendar: &Component, name: &str, dt: DateTime) -> Option<Offset> {
    let zone = calendar
        .all("VTIMEZONE")
        .find(|z| z.value("TZID").as_deref() == Some(name))?;
    let mut latest: Option<(DateTime, Offset)> = None;
    let mut last_in_year: Option<(DateTime, Offset)> = None;
    for part in zone.all("STANDARD").chain(zone.all("DAYLIGHT")) {
        let offset = parse_offset(&part.value("TZOFFSETTO")?)?;
        let (start, _) = civil(&part.value("DTSTART")?)?;
        let begins = match part.value("RRULE") {
            Some(rule) => yearly(&rule, start, dt.year()).unwrap_or(start),
            None => start,
        };
        if begins <= dt && latest.is_none_or(|(at, _)| begins > at) {
            latest = Some((begins, offset));
        }
        if last_in_year.is_none_or(|(at, _)| begins > at) {
            last_in_year = Some((begins, offset));
        }
    }
    // Before this year's first change, last year's last one holds.
    latest.or(last_in_year).map(|(_, offset)| offset)
}

/// When a yearly `rule` (from `start`) changes in `year`.
fn yearly(rule: &str, start: DateTime, year: i16) -> Option<DateTime> {
    let part = |key: &str| {
        rule.split(';')
            .find_map(|p| p.strip_prefix(key)?.strip_prefix('='))
    };
    let month: i8 = part("BYMONTH")?.parse().ok()?;
    let by_day = part("BYDAY")?;
    let (nth, day) = by_day.split_at(by_day.len().checked_sub(2)?);
    let weekday = match day {
        "MO" => Weekday::Monday,
        "TU" => Weekday::Tuesday,
        "WE" => Weekday::Wednesday,
        "TH" => Weekday::Thursday,
        "FR" => Weekday::Friday,
        "SA" => Weekday::Saturday,
        "SU" => Weekday::Sunday,
        _ => return None,
    };
    let nth: i8 = if nth.is_empty() { 1 } else { nth.parse().ok()? };
    let date = Date::new(year, month, 1)
        .ok()?
        .nth_weekday_of_month(nth, weekday)
        .ok()?;
    Some(date.to_datetime(start.time()))
}

/// `+0200` or `-0530` as an offset.
fn parse_offset(text: &str) -> Option<Offset> {
    let sign = match text.get(..1)? {
        "+" => 1,
        "-" => -1,
        _ => return None,
    };
    let hours = i32::from(two(text, 1)?);
    let minutes = i32::from(two(text, 3)?);
    Offset::from_seconds(sign * (hours * 3600 + minutes * 60)).ok()
}

/// Whether `line` is the ATTENDEE line for `me`.
fn is_me(line: &Line, me: &str) -> bool {
    line.name == "ATTENDEE" && address(&line.value).eq_ignore_ascii_case(me)
}

/// The invite in `ics`, for the account at `me`, its times in `local`.
pub fn read(ics: &str, me: &str, local: &TimeZone) -> Option<Invite> {
    let calendar = parse(ics)?;
    let event = calendar.event()?;
    let time = |name: &str| event.line(name).and_then(|l| when(l, &calendar, local));
    let start = time("DTSTART");
    let method = calendar
        .value("METHOD")
        .map_or_else(|| "REQUEST".to_string(), |m| m.to_ascii_uppercase());
    Some(Invite {
        cancelled: method == "CANCEL" || event.value("STATUS").as_deref() == Some("CANCELLED"),
        method,
        summary: event.value("SUMMARY").unwrap_or_default(),
        location: event.value("LOCATION").filter(|l| !l.trim().is_empty()),
        all_day: start.as_ref().is_some_and(|(_, day)| *day),
        start: start.map(|(at, _)| at),
        end: time("DTEND").map(|(at, _)| at),
        organizer: event.line("ORGANIZER").map(person),
        attendees: event
            .lines
            .iter()
            .filter(|l| l.name == "ATTENDEE")
            .map(person)
            .collect(),
        repeats: event.line("RRULE").is_some(),
        answer: event
            .lines
            .iter()
            .find(|l| is_me(l, me))
            .and_then(|l| l.param("PARTSTAT"))
            .map(str::to_ascii_uppercase),
    })
}

/// `me`'s `answer` to the invite in `ics`, made at `now`, as a REPLY to its
/// organizer; None when it has no event or no organizer to answer.
pub fn reply(ics: &str, me: &str, answer: Answer, now: Timestamp) -> Option<Reply> {
    let calendar = parse(ics)?;
    let event = calendar.event()?;
    let organizer = event.line("ORGANIZER")?;
    let summary = event.value("SUMMARY").unwrap_or_default();
    let mut out = vec![
        "BEGIN:VCALENDAR".to_string(),
        "PRODID:-//Greed//Mail//EN".to_string(),
        "VERSION:2.0".to_string(),
        "METHOD:REPLY".to_string(),
    ];
    // The zones its times are in, as the organizer wrote them.
    let zones: Vec<&str> = event.lines.iter().filter_map(|l| l.param("TZID")).collect();
    for zone in calendar.all("VTIMEZONE") {
        if zone
            .value("TZID")
            .is_some_and(|id| zones.contains(&id.as_str()))
        {
            write(zone, &mut out);
        }
    }
    out.push("BEGIN:VEVENT".to_string());
    for name in [
        "UID",
        "RECURRENCE-ID",
        "SEQUENCE",
        "DTSTART",
        "DTEND",
        "SUMMARY",
        "ORGANIZER",
    ] {
        if let Some(line) = event.line(name) {
            out.push(line.raw.clone());
        }
    }
    out.push(format!("DTSTAMP:{}", now.strftime("%Y%m%dT%H%M%SZ")));
    let mine = event.lines.iter().find(|l| is_me(l, me));
    let params: String = mine
        .map(|line| {
            line.params
                .iter()
                .filter(|(n, _)| !matches!(n.as_str(), "PARTSTAT" | "RSVP"))
                .map(|(n, v)| {
                    if v.contains([':', ';', ',']) {
                        format!(";{n}=\"{v}\"")
                    } else {
                        format!(";{n}={v}")
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    let address = mine.map_or_else(|| me.to_string(), |l| address(&l.value));
    out.push(format!(
        "ATTENDEE{params};PARTSTAT={}:mailto:{address}",
        answer.partstat()
    ));
    out.push("END:VEVENT".to_string());
    out.push("END:VCALENDAR".to_string());
    let calendar = out
        .iter()
        .map(|line| fold(line))
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n";
    Some(Reply {
        to: address_with_name(organizer),
        subject: format!("{}: {summary}", answer.word()),
        text: format!("{address} has {}.\n", answer.word().to_lowercase()),
        calendar,
    })
}

/// The organizer as a To header has it.
fn address_with_name(line: &Line) -> String {
    let at = address(&line.value);
    match line.param("CN") {
        Some(name) if !name.is_empty() => format!("\"{}\" <{at}>", name.replace('"', "")),
        _ => at,
    }
}

/// `component` as lines again.
fn write(component: &Component, out: &mut Vec<String>) {
    out.push(format!("BEGIN:{}", component.name));
    out.extend(component.lines.iter().map(|l| l.raw.clone()));
    for child in &component.children {
        write(child, out);
    }
    out.push(format!("END:{}", component.name));
}

/// `line` folded at 75 bytes, as iCalendar wants, never inside a character.
fn fold(line: &str) -> String {
    let mut out = String::with_capacity(line.len() + line.len() / 70 * 3);
    let mut width = 0;
    for c in line.chars() {
        if width + c.len_utf8() > 75 {
            out.push_str("\r\n ");
            width = 1;
        }
        out.push(c);
        width += c.len_utf8();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const INVITE: &str = "BEGIN:VCALENDAR\r\n\
PRODID:-//Example//EN\r\n\
VERSION:2.0\r\n\
METHOD:REQUEST\r\n\
BEGIN:VTIMEZONE\r\n\
TZID:W. Europe Standard Time\r\n\
BEGIN:STANDARD\r\n\
DTSTART:16010101T030000\r\n\
TZOFFSETFROM:+0200\r\n\
TZOFFSETTO:+0100\r\n\
RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n\
END:STANDARD\r\n\
BEGIN:DAYLIGHT\r\n\
DTSTART:16010101T020000\r\n\
TZOFFSETFROM:+0100\r\n\
TZOFFSETTO:+0200\r\n\
RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\n\
END:DAYLIGHT\r\n\
END:VTIMEZONE\r\n\
BEGIN:VEVENT\r\n\
UID:plan-42@example.com\r\n\
SEQUENCE:2\r\n\
SUMMARY:Garden plans\\, again\r\n\
LOCATION:The shed\r\n\
DTSTART;TZID=W. Europe Standard Time:20261024T100000\r\n\
DTEND;TZID=W. Europe Standard Time:20261024T110000\r\n\
ORGANIZER;CN=Bob Example:mailto:bob@example.com\r\n\
ATTENDEE;CN=Anna Berg;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:anna@example.com\r\n\
ATTENDEE;CN=Carl;PARTSTAT=ACCEPTED:mailto:carl@exa\r\n mple.com\r\n\
END:VEVENT\r\n\
END:VCALENDAR\r\n";

    fn utc() -> TimeZone {
        TimeZone::UTC
    }

    #[test]
    fn an_invite_reads_its_event_in_local_time() {
        let invite = read(INVITE, "Anna@Example.com", &utc()).unwrap();
        assert_eq!(invite.method, "REQUEST");
        assert_eq!(invite.summary, "Garden plans, again");
        assert_eq!(invite.location.as_deref(), Some("The shed"));
        // Summer time in October, from the invite's own zone: +02:00.
        assert_eq!(invite.start.as_deref(), Some("2026-10-24T08:00:00+00:00"));
        assert_eq!(invite.end.as_deref(), Some("2026-10-24T09:00:00+00:00"));
        assert!(!invite.all_day && !invite.repeats && !invite.cancelled);
        assert_eq!(invite.answer.as_deref(), Some("NEEDS-ACTION"));
        let organizer = invite.organizer.unwrap();
        assert_eq!(organizer.name.as_deref(), Some("Bob Example"));
        assert_eq!(organizer.address, "bob@example.com");
        let carl = &invite.attendees[1];
        assert_eq!(carl.address, "carl@example.com", "unfolded");
        assert_eq!(carl.answer.as_deref(), Some("ACCEPTED"));
    }

    #[test]
    fn a_zone_the_system_knows_and_winter_time_from_the_invites_own() {
        // Only where the system has a zone database, as Linux and macOS do.
        if TimeZone::get("Europe/Stockholm").is_ok() {
            let known = INVITE.replace("W. Europe Standard Time:", "Europe/Stockholm:");
            let invite = read(&known, "anna@example.com", &utc()).unwrap();
            assert_eq!(invite.start.as_deref(), Some("2026-10-24T08:00:00+00:00"));
        }
        let winter = INVITE.replace("20261024T1", "20261124T1");
        let invite = read(&winter, "anna@example.com", &utc()).unwrap();
        assert_eq!(invite.start.as_deref(), Some("2026-11-24T09:00:00+00:00"));
        let spring = INVITE.replace("20261024T1", "20260210T1");
        let invite = read(&spring, "anna@example.com", &utc()).unwrap();
        assert_eq!(
            invite.start.as_deref(),
            Some("2026-02-10T09:00:00+00:00"),
            "before the year's first change, last year's last holds"
        );
    }

    #[test]
    fn a_day_long_event_a_cancelled_one_and_utc() {
        let day = INVITE
            .replace(
                "DTSTART;TZID=W. Europe Standard Time:20261024T100000",
                "DTSTART;VALUE=DATE:20261024",
            )
            .replace("DTEND;TZID=W. Europe Standard Time:20261024T110000\r\n", "")
            .replace("METHOD:REQUEST", "METHOD:CANCEL");
        let invite = read(&day, "anna@example.com", &utc()).unwrap();
        assert!(invite.all_day && invite.cancelled);
        assert_eq!(invite.start.as_deref(), Some("2026-10-24"));
        assert_eq!(invite.end, None);
        let zulu = INVITE.replace(
            "DTSTART;TZID=W. Europe Standard Time:20261024T100000",
            "DTSTART:20261024T100000Z",
        );
        let plus_two = TimeZone::fixed(Offset::from_hours(2).unwrap());
        let invite = read(&zulu, "anna@example.com", &plus_two).unwrap();
        assert_eq!(invite.start.as_deref(), Some("2026-10-24T12:00:00+02:00"));
        assert_eq!(
            read("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", "a", &utc()),
            None
        );
    }

    #[test]
    fn a_reply_answers_the_organizer_as_the_invite_names_you() {
        let now = Timestamp::from_second(1_792_000_000).unwrap();
        let reply = reply(INVITE, "anna@example.com", Answer::Tentative, now).unwrap();
        assert_eq!(reply.to, "\"Bob Example\" <bob@example.com>");
        assert_eq!(reply.subject, "Tentative: Garden plans, again");
        let lines = unfold(&reply.calendar);
        let has = |line: &str| lines.iter().any(|l| l == line);
        assert!(has("METHOD:REPLY"), "{lines:?}");
        assert!(has("UID:plan-42@example.com"));
        assert!(has("SEQUENCE:2"));
        assert!(has("TZID:W. Europe Standard Time"), "its zone goes along");
        assert!(
            has(
                "ATTENDEE;CN=Anna Berg;ROLE=REQ-PARTICIPANT;PARTSTAT=TENTATIVE:mailto:anna@example.com"
            ),
            "{lines:?}"
        );
        assert!(!reply.calendar.contains("carl"), "only you answer");
        assert!(reply.calendar.lines().all(|l| l.len() <= 76));
        let back = read(&reply.calendar, "anna@example.com", &utc()).unwrap();
        assert_eq!(back.answer.as_deref(), Some("TENTATIVE"));
        assert_eq!(back.method, "REPLY");
        assert_eq!(back.start.as_deref(), Some("2026-10-24T08:00:00+00:00"));
        let alias = super::reply(INVITE, "me@else.example", Answer::Declined, now).unwrap();
        assert!(
            alias
                .calendar
                .contains("PARTSTAT=DECLINED:mailto:me@else.example")
        );
    }
}
