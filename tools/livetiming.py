"""F1 live-timing archive as an OpenF1 stand-in, for the seasons OpenF1 doesn't have (before 2023).

update_db.py asks OpenF1 for meetings, sessions, weather, laps, stints, race control, drivers, car data and
locations. OpenF1 starts in 2023. The same data for earlier seasons is in F1's own live-timing archive (the
feed OpenF1 is built from): https://livetiming.formula1.com/static/<year>/...  Since October 2026 that needs
an F1 TV login (HTTP 401 without it). FastF1 keeps a public copy of 2021 and 2022:
https://livetiming-mirror.fastf1.dev/static/...  This module reads either and answers in OpenF1's format, so the
rest of the updater works unchanged.

  * Seasons: LT_YEARS. A season is used when its Index.json can be read: from the mirror, else from F1 with
    the token in the F1TV_TOKEN environment variable (a GitHub secret; never stored in the repo).
  * Keys: session_key / meeting_key = KEY_BASE + the archive's own key, so they never clash with OpenF1's.
  * 2021 called the Saturday sprint race 'Sprint Qualifying': it is a race here ('Sprint').
  * Two races at one circuit in a season (2020 Austria / Britain / Bahrain, 2021 Austria): the second one gets
    its own circuit name, e.g. 'Spielberg (Styrian GP)', so it has its own rows, sector lines and corner speeds.

Standard library only (zlib for the compressed car-data and position streams).
"""
import base64, json, os, sys, time, urllib.error, urllib.parse, urllib.request, zlib
from datetime import datetime, timedelta, timezone

OFFICIAL = 'https://livetiming.formula1.com/static/'
MIRROR = 'https://livetiming-mirror.fastf1.dev/static/'
LT_YEARS = (2020, 2021, 2022)
KEY_BASE = 1_000_000


def _clean_token(t):
    """The F1 TV subscriptionToken, also when the secret holds the whole login-session cookie (URL-encoded JSON),
    a 'Bearer ...' line or quotes."""
    t = (t or '').strip().strip('"').strip("'").strip()
    if t.lower().startswith('bearer '):
        t = t[7:].strip()
    if '%7B' in t or '%22' in t:
        t = urllib.parse.unquote(t)
    if t.startswith('{'):
        try:
            j = json.loads(t)
            t = ((j.get('data') or {}).get('subscriptionToken') or j.get('subscriptionToken') or '').strip()
        except Exception:
            pass
    return t


TOKEN = _clean_token(os.environ.get('F1TV_TOKEN'))
STATUS = {}                      # url -> last HTTP status (for the log)


def is_lt_key(k):
    try:
        return int(k) >= KEY_BASE
    except (TypeError, ValueError):
        return False


# --------------------------------------------------------------------------------------------- download
def _get(url, auth=False, tries=4):
    for attempt in range(tries):
        try:
            headers = {'User-Agent': 'F1TrueConditions-updater/2.0'}
            if auth and TOKEN:
                headers['Authorization'] = 'Bearer ' + TOKEN
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=90) as r:
                STATUS[url] = r.status
                body = r.read().decode('utf-8-sig')
                if auth and body.lstrip().startswith('{') and '"Fault"' in body[:200]:
                    STATUS[url] = 'fault'                # F1's way of saying the login has expired
                    return None
                return body
        except urllib.error.HTTPError as e:
            STATUS[url] = e.code
            if e.code in (401, 403, 404):
                return None
            if attempt < tries - 1:
                time.sleep(3 * (attempt + 1)); continue
            return None
        except Exception:
            if attempt < tries - 1:
                time.sleep(3 * (attempt + 1)); continue
            return None


_base_of_year = {}


def fetch(path, year):
    """A file of the archive: from the mirror first, then from F1 with the F1 TV token (if set)."""
    order = [(MIRROR, False)] + ([(OFFICIAL, True)] if TOKEN else [])
    if year in _base_of_year:                     # where this season's index was found first
        order.sort(key=lambda b: b[0] != _base_of_year[year])
    quoted = urllib.parse.quote(path, safe='/')
    for base, auth in order:
        txt = _get(base + quoted, auth)
        if txt is not None:
            return txt
    return None


def stream(txt):
    """[(seconds into the stream, object)] of a .jsonStream file ('HH:MM:SS.mmm{json}' lines)."""
    out = []
    for line in (txt or '').splitlines():
        line = line.strip()
        if len(line) < 13:
            continue
        try:
            h, m, s = line[:12].split(':')
            t = int(h) * 3600 + int(m) * 60 + float(s)
            out.append((t, json.loads(line[12:])))
        except Exception:
            continue
    return out


def inflate(b64):
    return json.loads(zlib.decompress(base64.b64decode(b64), -zlib.MAX_WBITS))


def utc(s):
    """Archive time ('2021-03-27T14:45:05.32Z', sometimes without Z / with 7 decimals) -> aware datetime."""
    s = str(s).rstrip('Z')
    if '.' in s:
        a, b = s.split('.', 1)
        s = a + '.' + (b + '000000')[:6]
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def iso(dt):
    return dt.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + '+00:00'


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def laptime(v):
    """'1:31.200' / '28.819' -> seconds."""
    v = str(v or '').strip()
    if not v:
        return None
    try:
        if ':' in v:
            m, s = v.split(':')
            return int(m) * 60 + float(s)
        return float(v)
    except ValueError:
        return None


# --------------------------------------------------------------------------------------------- calendar
SPRINT_RENAME = {2021: {'Sprint Qualifying': 'Sprint'}}     # 2021's Saturday sprint was a race
_years, _sessions = {}, {}                                  # year -> (meetings, sessions); key -> session


# 2020: the archive has no season index for it, so the sessions are looked up one by one (race day, event name,
# and the days of its sessions; each session's own SessionInfo.json gives the exact times and keys). FP2 of the
# Eifel GP was the only session that day (FP1 was fogged off), Imola had a two-day weekend.
CAL_2020 = [
    ('2020-07-05', 'Austrian Grand Prix', '07-03', '07-04'), ('2020-07-12', 'Styrian Grand Prix', '07-10', '07-11'),
    ('2020-07-19', 'Hungarian Grand Prix', '07-17', '07-18'), ('2020-08-02', 'British Grand Prix', '07-31', '08-01'),
    ('2020-08-09', '70th Anniversary Grand Prix', '08-07', '08-08'), ('2020-08-16', 'Spanish Grand Prix', '08-14', '08-15'),
    ('2020-08-30', 'Belgian Grand Prix', '08-28', '08-29'), ('2020-09-06', 'Italian Grand Prix', '09-04', '09-05'),
    ('2020-09-13', 'Tuscan Grand Prix', '09-11', '09-12'), ('2020-09-27', 'Russian Grand Prix', '09-25', '09-26'),
    ('2020-10-11', 'Eifel Grand Prix', '10-09', '10-10'), ('2020-10-25', 'Portuguese Grand Prix', '10-23', '10-24'),
    ('2020-11-01', 'Emilia Romagna Grand Prix', '10-31', '10-31'), ('2020-11-15', 'Turkish Grand Prix', '11-13', '11-14'),
    ('2020-11-29', 'Bahrain Grand Prix', '11-27', '11-28'), ('2020-12-06', 'Sakhir Grand Prix', '12-04', '12-05'),
    ('2020-12-13', 'Abu Dhabi Grand Prix', '12-11', '12-12'),
]


def _index_from_calendar(year, cal):
    """An Index.json-like season built from each session's SessionInfo.json (official archive, F1 TV token)."""
    meetings = []
    for race_day, name, fri, sat in cal:
        folder = f'{year}/{race_day}_{name.replace(" ", "_")}/'
        tries = [('Practice 1', fri), ('Practice 2', fri), ('Practice 3', sat), ('Qualifying', sat), ('Race', race_day[5:])]
        m = None
        for sname, day in tries:
            path = f'{folder}{year}-{day}_{sname.replace(" ", "_")}/'
            txt = _get(OFFICIAL + urllib.parse.quote(path + 'SessionInfo.json', safe='/'), True)
            if not txt:
                continue
            try:
                si = json.loads(txt)
            except Exception:
                continue
            if m is None:
                mt = si.get('Meeting') or {}
                m = {'Key': mt.get('Key'), 'Name': mt.get('Name') or name, 'Location': mt.get('Location'),
                     'Country': mt.get('Country') or {}, 'Circuit': mt.get('Circuit') or {}, 'Sessions': []}
            m['Sessions'].append({'Key': si.get('Key'), 'Name': si.get('Name') or sname, 'StartDate': si.get('StartDate'),
                                  'EndDate': si.get('EndDate'), 'GmtOffset': si.get('GmtOffset'), 'Path': si.get('Path') or path})
        if m and m.get('Key'):
            meetings.append(m)
        elif not meetings:
            return None                       # not even the first event: the login doesn't work, stop asking
    return {'Meetings': meetings} if meetings else None


def _why_not(year):
    if not TOKEN:
        return 'no F1TV_TOKEN secret reached the updater (the mirror only has 2021-2022)'
    st = STATUS.get(f'{OFFICIAL}{year}/Index.json')
    probe = [v for k, v in STATUS.items() if k.startswith(OFFICIAL) and k.endswith('SessionInfo.json')]
    st2 = probe[0] if probe else None
    what = {401: 'refused (401): the token is wrong or has expired', 403: 'refused (403): the token is wrong or has expired',
            'fault': 'answered "session expired": log in to F1 TV again and update the secret',
            404: 'not found (404)'}
    return (f'F1TV_TOKEN is set ({len(TOKEN)} characters); F1\'s archive {what.get(st2, what.get(st, f"answered {st2 or st}"))}')


def season(year):
    if year in _years:
        return _years[year]
    meetings, sessions = [], []
    txt = None
    for base, auth in [(MIRROR, False)] + ([(OFFICIAL, True)] if TOKEN else []):
        txt = _get(f'{base}{year}/Index.json', auth)
        if txt:
            _base_of_year[year] = base
            break
    idx = json.loads(txt) if txt else None
    if idx is None and year == 2020 and TOKEN:
        idx = _index_from_calendar(year, CAL_2020)
        if idx:
            _base_of_year[year] = OFFICIAL
    if not idx:
        print(f'  live timing {year}: not available, {_why_not(year)}', file=sys.stderr)
        _years[year] = ([], [])
        return _years[year]
    short_count = {}
    for m in idx.get('Meetings') or []:
        if 'test' in (m.get('Name') or '').lower():
            continue
        sn = (m.get('Circuit') or {}).get('ShortName') or m.get('Location') or ''
        short_count[sn] = short_count.get(sn, 0) + 1
    HOME = ('Austrian Grand Prix', 'British Grand Prix', 'Bahrain Grand Prix')
    for m in idx.get('Meetings') or []:
        name = m.get('Name') or ''
        if 'test' in name.lower():
            continue
        sn = (m.get('Circuit') or {}).get('ShortName') or m.get('Location') or ''
        circuit = sn
        if short_count.get(sn, 0) > 1 and name not in HOME:
            # second race at the same circuit this season: its own name ('Spielberg (Styrian GP)')
            circuit = f'{sn} ({name.replace(" Grand Prix", " GP")})'
        mk = KEY_BASE + int(m['Key'])
        meetings.append({'meeting_key': mk, 'meeting_name': name, 'year': year})
        race = next((s for s in m.get('Sessions') or [] if s.get('Name') == 'Race'), None)
        race_day = (race or (m.get('Sessions') or [{}])[-1]).get('StartDate', '')[:10]
        for s in m.get('Sessions') or []:
            sname = s.get('Name') or ''
            if not s.get('StartDate') or not s.get('Key'):
                continue
            off = s.get('GmtOffset') or '00:00:00'
            neg = off.startswith('-')
            hh, mm, ss = [int(x) for x in off.lstrip('-').split(':')]
            d = timedelta(hours=hh, minutes=mm, seconds=ss) * (-1 if neg else 1)
            start = datetime.fromisoformat(s['StartDate']) - d
            end = (datetime.fromisoformat(s['EndDate']) - d) if s.get('EndDate') else start + timedelta(hours=1)
            path = s.get('Path') or (f'{year}/{race_day}_{name.replace(" ", "_")}/'
                                     f'{s["StartDate"][:10]}_{sname.replace(" ", "_")}/')
            sk = KEY_BASE + int(s['Key'])
            rec = {'session_key': sk, 'meeting_key': mk, 'year': year,
                   'session_name': SPRINT_RENAME.get(year, {}).get(sname, sname), 'lt_name': sname,
                   'date_start': start.replace(tzinfo=timezone.utc).isoformat(),
                   'date_end': end.replace(tzinfo=timezone.utc).isoformat(), 'gmt_offset': off,
                   'circuit_short_name': circuit, 'location': m.get('Location') or '',
                   'country_name': (m.get('Country') or {}).get('Name') or '', 'is_cancelled': False,
                   '_path': path}
            sessions.append(rec)
            _sessions[sk] = rec
    _years[year] = (meetings, sessions)
    print(f'  live timing {year}: {len(meetings)} events from {_base_of_year[year]}', file=sys.stderr)
    return _years[year]


def session(sk):
    sk = int(sk)
    if sk not in _sessions:
        for y in LT_YEARS:
            season(y)
    return _sessions.get(sk)


# --------------------------------------------------------------------------------------------- one session
class Session:
    """All the data of one archived session, parsed once."""

    def __init__(self, s):
        self.s, self.year, self.path = s, s['year'], s['_path']
        self._cache = {}

    def file(self, name):
        if name not in self._cache:
            self._cache[name] = fetch(self.path + name, self.year)
        return self._cache[name]

    # time of second 0 of the .jsonStream files: from the extrapolated clock (offset <-> UTC), else race control
    def t0(self):
        if 't0' in self._cache:
            return self._cache['t0']
        t0 = None
        for t, o in stream(self.file('ExtrapolatedClock.jsonStream')):
            if isinstance(o, dict) and o.get('Utc'):
                t0 = utc(o['Utc']) - timedelta(seconds=t)
                break
        if t0 is None:
            for t, o in stream(self.file('RaceControlMessages.jsonStream')):
                msgs = (o or {}).get('Messages')
                vals = msgs.values() if isinstance(msgs, dict) else (msgs or [])
                for m in vals:
                    if m.get('Utc'):
                        t0 = utc(m['Utc']) - timedelta(seconds=t)
                        break
                if t0:
                    break
        if t0 is None:
            t0 = datetime.fromisoformat(self.s['date_start']) - timedelta(minutes=15)
        self._cache['t0'] = t0
        return t0

    def weather(self):
        t0, out = self.t0(), []
        for t, o in stream(self.file('WeatherData.jsonStream')):
            if not isinstance(o, dict) or 'AirTemp' not in o:
                continue
            out.append({'date': iso(t0 + timedelta(seconds=t)), 'air_temperature': num(o.get('AirTemp')),
                        'track_temperature': num(o.get('TrackTemp')), 'humidity': num(o.get('Humidity')),
                        'pressure': num(o.get('Pressure')), 'rainfall': 1 if (num(o.get('Rainfall')) or 0) > 0 else 0,
                        'wind_speed': num(o.get('WindSpeed')), 'wind_direction': num(o.get('WindDirection')),
                        'session_key': self.s['session_key']})
        return out

    def phases(self):
        """[(utc, qualifying part)] from SessionData (TimingData's SessionPart as a fallback)."""
        out = []
        try:
            sd = json.loads(self.file('SessionData.json') or '{}')
            for x in sd.get('Series') or []:
                if x.get('Utc') and 'QualifyingPart' in x:
                    out.append((utc(x['Utc']), int(x['QualifyingPart'])))
        except Exception:
            out = []
        if not out:
            t0 = self.t0()
            for t, o in stream(self.file('TimingData.jsonStream')):
                if isinstance(o, dict) and isinstance(o.get('SessionPart'), int):
                    out.append((t0 + timedelta(seconds=t), o['SessionPart']))
        return sorted(out)

    def race_control(self):
        quali = self.s['session_name'] in ('Qualifying', 'Sprint Qualifying', 'Sprint Shootout')
        ph = self.phases() if quali else []
        out = []
        try:
            msgs = json.loads(self.file('RaceControlMessages.json') or '{}').get('Messages') or []
        except Exception:
            msgs = []
        for m in msgs:
            if not m.get('Utc'):
                continue
            d = utc(m['Utc'])
            p = None
            if ph:
                cur = [q for t, q in ph if t <= d + timedelta(seconds=1)]
                p = cur[-1] if cur and cur[-1] in (1, 2, 3) else None
            out.append({'date': iso(d), 'category': m.get('Category'), 'flag': m.get('Flag'), 'scope': m.get('Scope'),
                        'message': m.get('Message') or '', 'qualifying_phase': p, 'session_key': self.s['session_key']})
        return out

    def drivers(self):
        try:
            dl = json.loads(self.file('DriverList.json') or '{}')
        except Exception:
            dl = {}
        out = []
        for k, d in dl.items():
            if not isinstance(d, dict) or not str(k).isdigit():
                continue
            out.append({'driver_number': int(k), 'name_acronym': d.get('Tla') or '', 'team_name': d.get('TeamName') or '',
                        'team_colour': d.get('TeamColour') or '', 'last_name': (d.get('LastName') or '').title(),
                        'session_key': self.s['session_key']})
        return out

    def laps(self):
        """OpenF1-style laps from TimingData: a lap ends when the driver's NumberOfLaps goes up; its time is the
        LastLapTime sent with it, its sectors the three sector values sent during it; a lap started from the pit
        exit (PitOut) is an out-lap."""
        if 'laps' in self._cache:
            return self._cache['laps']
        t0 = self.t0()
        st, out = {}, []
        for t, o in stream(self.file('TimingData.jsonStream')):
            lines = (o or {}).get('Lines') if isinstance(o, dict) else None
            if not isinstance(lines, dict):
                continue
            for dn, x in lines.items():
                if not isinstance(x, dict) or not str(dn).isdigit():
                    continue
                d = st.setdefault(dn, {'n': None, 'sec': [None, None, None], 'pitout': False, 'last': None, 'open': None})
                sec = x.get('Sectors')
                items = sec.items() if isinstance(sec, dict) else (enumerate(sec) if isinstance(sec, list) else [])
                for i, v in items:
                    i = int(i)
                    if 0 <= i <= 2 and isinstance(v, dict) and 'Value' in v:
                        val = laptime(v.get('Value'))
                        if val:
                            d['sec'][i] = val
                        elif v.get('Value') == '' and i > 0:
                            d['sec'][i] = None
                llt = x.get('LastLapTime')
                lt = laptime(llt.get('Value')) if isinstance(llt, dict) else None
                if x.get('PitOut') is True:
                    d['pitout'] = True
                n = x.get('NumberOfLaps')
                if isinstance(n, int):
                    if d['n'] is not None and n > d['n']:
                        end = t0 + timedelta(seconds=t)
                        lap = {'driver_number': int(dn), 'lap_number': n - 1, 'session_key': self.s['session_key'],
                               'lap_duration': lt, 'is_pit_out_lap': d['pitout'], '_end': end,
                               'duration_sector_1': d['sec'][0], 'duration_sector_2': d['sec'][1],
                               'duration_sector_3': d['sec'][2]}
                        out.append(lap)
                        d['open'] = (lap, t)
                        d['sec'], d['pitout'] = [None, None, None], x.get('PitOut') is True
                        lt = None
                    d['n'] = n
                elif lt and d['open'] and t - d['open'][1] < 3 and not d['open'][0]['lap_duration']:
                    d['open'][0]['lap_duration'] = lt          # lap time sent just after the line
        for lap in out:
            if lap['lap_duration']:
                lap['date_start'] = iso(lap['_end'] - timedelta(seconds=lap['lap_duration']))
                secs = [lap[f'duration_sector_{i}'] for i in (1, 2, 3)]
                if not all(secs) or abs(sum(secs) - lap['lap_duration']) > 0.05:
                    for i in (1, 2, 3):
                        lap[f'duration_sector_{i}'] = None     # sectors of another lap: don't use them
            else:
                lap['date_start'] = None
            del lap['_end']
        out.sort(key=lambda l: (l['driver_number'], l['lap_number']))
        self._cache['laps'] = out
        return out

    def stints(self):
        try:
            tad = json.loads(self.file('TimingAppData.json') or '{}').get('Lines') or {}
        except Exception:
            tad = {}
        out = []
        for dn, x in tad.items():
            sts = x.get('Stints') if isinstance(x, dict) else None
            sts = list(sts.values()) if isinstance(sts, dict) else (sts or [])
            lap = 1
            for i, st in enumerate(sts):
                n = max(0, int(st.get('TotalLaps') or 0) - int(st.get('StartLaps') or 0))
                out.append({'driver_number': int(dn), 'stint_number': i + 1, 'lap_start': lap,
                            'lap_end': lap + max(0, n - 1), 'compound': (st.get('Compound') or '').upper(),
                            'session_key': self.s['session_key']})
                lap += n
        return out

    def _z(self, name, kind):
        """{driver: [(utc, record)]} from CarData.z / Position.z (base64 + raw deflate JSON per line)."""
        if name in self._cache and isinstance(self._cache[name], dict):
            return self._cache[name]
        out = {}
        for line in (self.file(name + '.jsonStream') or '').splitlines():
            line = line.strip()
            if len(line) < 14:
                continue
            try:
                o = inflate(line[12:].strip().strip('"'))
            except Exception:
                continue
            if kind == 'car':
                for e in o.get('Entries') or []:
                    tt = utc(e['Utc'])
                    for dn, c in (e.get('Cars') or {}).items():
                        ch = c.get('Channels') or {}
                        out.setdefault(int(dn), []).append((tt, ch))
            else:
                for e in o.get('Position') or []:
                    tt = utc(e['Timestamp'])
                    for dn, p in (e.get('Entries') or {}).items():
                        out.setdefault(int(dn), []).append((tt, p))
        for v in out.values():
            v.sort(key=lambda a: a[0])
        self._cache[name] = out
        return out

    def car_data(self, driver, lo=None, hi=None):
        res = []
        for tt, ch in self._z('CarData.z', 'car').get(int(driver), []):
            if (lo and tt <= lo) or (hi and tt >= hi):
                continue
            br = ch.get('5')
            if br in (0, 1):
                br = br * 100                               # archive: 0 / 1, OpenF1: 0 / 100
            res.append({'date': iso(tt), 'speed': ch.get('2'), 'throttle': ch.get('4'), 'brake': br,
                        'rpm': ch.get('0'), 'n_gear': ch.get('3'), 'drs': ch.get('45'), 'driver_number': int(driver)})
        return res

    def location(self, driver, lo=None, hi=None):
        res = []
        for tt, p in self._z('Position.z', 'pos').get(int(driver), []):
            if (lo and tt <= lo) or (hi and tt >= hi):
                continue
            if p.get('X') is None or (p.get('X') == 0 and p.get('Y') == 0):
                continue
            res.append({'date': iso(tt), 'x': p.get('X'), 'y': p.get('Y'), 'z': p.get('Z'), 'driver_number': int(driver)})
        return res


_open = {}


def _sess(sk):
    sk = int(sk)
    if sk not in _open:
        if len(_open) >= 2:                             # keep memory low: the two most recent sessions
            _open.pop(next(iter(_open)))
        s = session(sk)
        if not s:
            return None
        _open[sk] = Session(s)
    return _open[sk]


def _date_bound(params, key):
    v = params.get(key)
    return datetime.fromisoformat(v).replace(tzinfo=timezone.utc) if v else None


def query(path, params):
    """OpenF1-style answer for an archived season / session."""
    if path in ('meetings', 'sessions'):
        meetings, sessions = season(int(params['year']))
        return meetings if path == 'meetings' else sessions
    s = _sess(params['session_key'])
    if s is None:
        return []
    if path == 'weather':
        return s.weather()
    if path == 'race_control':
        return s.race_control()
    if path == 'drivers':
        return s.drivers()
    if path == 'laps':
        return s.laps()
    if path == 'stints':
        return s.stints()
    if path in ('car_data', 'location'):
        lo, hi = _date_bound(params, 'date>'), _date_bound(params, 'date<')
        fn = s.car_data if path == 'car_data' else s.location
        return fn(params['driver_number'], lo, hi)
    return []
