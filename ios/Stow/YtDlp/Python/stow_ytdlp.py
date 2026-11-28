"""The app's side of yt-dlp (see PythonRuntime.swift).

Swift submits a JSON request with a call id; each runs on a Python thread of its own, so a long
download doesn't hold up a search (the GIL is released while yt-dlp waits on the network). Answers go
back through _stow.emit as "progress", "result", "error" or "cancelled". A cancelled call stops at
the next HTTP request or download progress update.
"""

import collections
import contextlib
import copy
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import traceback

import _stow

_ready = threading.Event()
# The call running on this thread, for code yt-dlp calls without one (its sleeps).
_current = threading.local()
_load_error = None
_cache_dir = None
_YDL = None
_Cancelled = None
_javascript = {'enabled': True}
# Prints all of yt-dlp's messages to the system log (configure {"debug": true}).
_debug = {'enabled': False}

# yt-dlp's max_comments: in all, top-level, replies in all, replies per thread (as on Android).
COMMENT_LIMITS = ['80', '40', '60', '6']
# Downloads and streams are H.264 + AAC: no ffmpeg on iOS, so AVFoundation merges, and it only
# passes through what an MP4 can hold. YouTube has no H.264 above 1080p.
MAX_HEIGHT = 1080
_DOWNLOAD_FORMAT = (
    'bv*[vcodec^=avc1][ext=mp4][protocol^=http]+ba[ext=m4a][protocol^=http]'
    '/b[vcodec^=avc1][ext=mp4][protocol^=http]'
)


def start(cache_dir):
    """Called once by StowPython.c. Imports yt-dlp in the background so the first call is quicker."""
    global _cache_dir
    _cache_dir = cache_dir
    os.makedirs(cache_dir, exist_ok=True)
    _prune(os.path.join(cache_dir, 'yt-dlp', 'challenge-solver'), max_age_days=14)
    threading.Thread(target=_load, name='stow-load', daemon=True).start()


def _prune(directory, max_age_days):
    """YouTube's player changes every week or two; yt-dlp never deletes the old ones."""
    cutoff = time.time() - max_age_days * 86400
    with contextlib.suppress(OSError):
        for entry in os.scandir(directory):
            if entry.name.startswith('player') and entry.stat().st_mtime < cutoff:
                with contextlib.suppress(OSError):
                    os.remove(entry.path)


def _load():
    global _load_error, _YDL, _Cancelled
    try:
        # iOS has no CA bundle that OpenSSL can find.
        import certifi
        os.environ['SSL_CERT_FILE'] = certifi.where()
        import yt_dlp
        from yt_dlp.utils import DownloadCancelled

        class Cancelled(DownloadCancelled):
            msg = 'Cancelled'

        class StowYoutubeDL(yt_dlp.YoutubeDL):
            stow_call = None

            def urlopen(self, req):
                if self.stow_call is not None:
                    self.stow_call.check()
                return super().urlopen(req)

        _Cancelled = Cancelled
        _YDL = StowYoutubeDL
        # yt-dlp waits before some downloads ("Sleeping 6 seconds as required by the site"); a
        # cancelled download shouldn't sit that out.
        import yt_dlp.downloader.common
        yt_dlp.downloader.common.time = _InterruptibleTime()
        _register_javascriptcore()
    except BaseException as error:
        _load_error = f'{type(error).__name__}: {error}'
        traceback.print_exc()
    finally:
        _ready.set()


class _InterruptibleTime:
    """The time module, with a sleep that stops when the thread's call is cancelled."""

    def __getattr__(self, name):
        return getattr(time, name)

    @staticmethod
    def sleep(seconds):
        call = getattr(_current, 'call', None)
        end = time.monotonic() + max(0, seconds)
        while True:
            if call is not None:
                call.check()
            left = end - time.monotonic()
            if left <= 0:
                return
            time.sleep(min(left, 0.1))


def _register_javascriptcore():
    """yt-dlp solves YouTube's JavaScript challenges with a JS runtime; on iOS that's JavaScriptCore."""
    from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
    from yt_dlp.extractor.youtube.jsc.provider import register_preference, register_provider
    from yt_dlp.utils._jsruntime import JsRuntimeInfo

    @register_provider
    class JavaScriptCoreJCP(EJSBaseJCP):
        PROVIDER_NAME = 'javascriptcore'
        JS_RUNTIME_NAME = 'javascriptcore'
        PROVIDER_VERSION = '1.0.0'
        BUG_REPORT_LOCATION = '(Stow for iPhone)'
        # Parsing YouTube's player (about 3 MB of JavaScript) is most of the work, and JavaScriptCore
        # has no JIT in an iOS app: keep the parsed player on disk (pruned in start()).
        _ENABLE_PREPROCESSED_PLAYER_CACHE = True

        @property
        def runtime_info(self):
            if not _javascript['enabled']:
                return None
            return JsRuntimeInfo('javascriptcore', 'builtin', '1.0.0', (1, 0, 0), True)

        def _run_js_runtime(self, stdin, /):
            return _stow.js_eval(stdin)

    @register_preference(JavaScriptCoreJCP)
    def _preference(provider, requests):
        return 1000


def submit(call_id, request_json):
    threading.Thread(target=_run, args=(call_id, request_json), name=f'stow-call-{call_id}', daemon=True).start()


def _run(call_id, request_json):
    call = _Call(call_id)
    _current.call = call
    try:
        _ready.wait()
        if _load_error:
            raise RuntimeError(f'yt-dlp could not start ({_load_error})')
        request = json.loads(request_json)
        op = _OPS.get(request.get('op'))
        if op is None:
            raise ValueError(f'unknown request {request.get("op")!r}')
        result = op(call, request)
        payload = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
        _stow.emit(call_id, 'result', payload)
    except BaseException as error:
        if call.is_cancelled() or (_Cancelled and isinstance(error, _Cancelled)):
            _stow.emit(call_id, 'cancelled', '')
        else:
            message = call.summary(error)
            print(f'[stow] call {call_id} failed: {message}', file=sys.stderr)
            _stow.emit(call_id, 'error', json.dumps({'message': message}, ensure_ascii=False))


class _Call:
    """One request: its cancellation flag and yt-dlp's messages (it is the YoutubeDL logger)."""

    def __init__(self, call_id):
        self.id = call_id
        self.errors = []
        self.warnings = []
        self.lines = collections.deque(maxlen=20)
        self._last_progress = 0.0

    def is_cancelled(self):
        return _stow.cancelled(self.id)

    def check(self):
        if self.is_cancelled():
            raise _Cancelled()

    def progress(self, data, force=False):
        now = time.monotonic()
        if force or now - self._last_progress >= 0.25:
            self._last_progress = now
            _stow.emit(self.id, 'progress', json.dumps(data))

    # yt-dlp's logger interface
    def debug(self, message):
        if _debug['enabled']:
            print(f'[yt-dlp {self.id} {time.monotonic():.3f}] {message}', file=sys.stderr)
        if not message.startswith('[debug] '):
            self.lines.append(message)

    def info(self, message):
        self.debug(message)

    def warning(self, message):
        self.lines.append(f'WARNING: {message}')
        self.warnings.append(message)
        # iOS has no ffmpeg by design (AVFoundation merges), and yt-dlp says so on every call.
        if 'ffmpeg not found' not in message and 'Unknown codec' not in message:
            print(f'[yt-dlp {self.id}] WARNING: {message}', file=sys.stderr)

    def error(self, message):
        self.errors.append(message)
        self.lines.append(message)

    def summary(self, error):
        """yt-dlp's ERROR lines, short enough for a status (like Android's YtDlp.summary)."""
        lines = [line.strip() for line in (self.errors or [str(error)]) if line and line.strip()]
        if not lines:
            lines = [line for line in self.lines if line.strip()][-2:] or [type(error).__name__]
        cleaned = []
        for line in lines:
            line = re.sub(r'^ERROR:\s*', '', line)
            # "[youtube] abc123: Video unavailable" -> "Video unavailable"
            line = re.sub(r'^\[[\w:-]+\]\s+[\w-]+:\s*', '', line)
            cleaned.append(line)
        return '\n'.join(dict.fromkeys(cleaned))[:300] or 'yt-dlp failed'


@contextlib.contextmanager
def _session(call, request, **options):
    """A YoutubeDL for one call, with a private copy of the cookies (yt-dlp writes the file back on close)."""
    cookie_copy = None
    try:
        params = {
            'quiet': True,
            'noprogress': True,
            'logger': call,
            'cachedir': os.path.join(_cache_dir, 'yt-dlp'),
            'noplaylist': True,
            'socket_timeout': 20,
            'retries': 3,
            'fragment_retries': 5,
            # Not a runtime yt-dlp would start as a process: JavaScriptCoreJCP is registered instead.
            'js_runtimes': {},
            'updatetime': False,
            'fixup': 'never',
            'verbose': _debug['enabled'],
        }
        youtube_args = {}
        if request.get('player_client'):
            youtube_args['player_client'] = list(request['player_client'])
        if request.get('youtube_args'):
            youtube_args.update({key: list(value) for key, value in request['youtube_args'].items()})
        # Flat listings (search, channel tabs) have no dates unless asked: this turns YouTube's
        # "3 days ago" into an approximate timestamp.
        params['extractor_args'] = {'youtubetab': {'approximate_date': ['']}}
        if youtube_args:
            params['extractor_args']['youtube'] = youtube_args
        cookies = request.get('cookies')
        if cookies:
            fd, cookie_copy = tempfile.mkstemp(prefix='cookies-', suffix='.txt', dir=_cache_dir)
            os.close(fd)
            os.chmod(cookie_copy, 0o600)
            shutil.copyfile(cookies, cookie_copy)
            params['cookiefile'] = cookie_copy
        params.update(options)
        with _YDL(params) as ydl:
            ydl.stow_call = call
            yield ydl
    finally:
        if cookie_copy:
            with contextlib.suppress(OSError):
                os.remove(cookie_copy)


def _watch_url(request):
    return request.get('url') or f'https://www.youtube.com/watch?v={request["id"]}'


def _select(ydl, raw, spec):
    """The formats `spec` picks from an unprocessed extractor result, or None when nothing matches."""
    from yt_dlp.utils import DownloadError, ExtractorError
    ydl.format_selector = ydl.build_format_selector(spec)
    errors = len(ydl.stow_call.errors)
    try:
        info = ydl.process_ie_result(copy.deepcopy(raw), download=False)
    except (DownloadError, ExtractorError):
        # "Requested format is not available" is an answer here, not the call's error.
        del ydl.stow_call.errors[errors:]
        return None, None
    return info, info.get('requested_formats') or [info]


def _size(fmt):
    size = fmt.get('filesize') or fmt.get('filesize_approx')
    return int(size) if size else None


def _part(fmt):
    has_video = fmt.get('vcodec') not in (None, 'none')
    has_audio = fmt.get('acodec') not in (None, 'none')
    return {
        'format_id': fmt['format_id'],
        'ext': fmt.get('ext'),
        'has_video': has_video,
        'has_audio': has_audio,
        'height': fmt.get('height'),
        'width': fmt.get('width'),
        'fps': fmt.get('fps'),
        'vcodec': fmt.get('vcodec'),
        'acodec': fmt.get('acodec'),
        'bytes': _size(fmt),
    }


def _plan(ydl, raw, max_height):
    height = max(144, min(int(max_height or MAX_HEIGHT), MAX_HEIGHT))
    ydl.params['format_sort'] = [f'res:{height}', 'fps', 'vcodec:h264', 'acodec:m4a']
    info, formats = _select(ydl, raw, _DOWNLOAD_FORMAT)
    if not formats:
        raise RuntimeError('This video has no format the iPhone can save')
    parts = [_part(f) for f in formats]
    sizes = [part['bytes'] for part in parts]
    return {
        'id': info.get('id'),
        'title': info.get('title'),
        'duration': info.get('duration'),
        'max_height': height,
        'parts': parts,
        'estimated_bytes': None if any(size is None for size in sizes) else sum(sizes),
    }


# MARK: - Requests

def _op_version(call, request):
    import ssl
    import yt_dlp.version
    return {
        'yt_dlp': yt_dlp.version.__version__,
        'python': sys.version.split()[0],
        'openssl': ssl.OPENSSL_VERSION,
        'javascript': _javascript['enabled'],
    }


def _op_configure(call, request):
    if 'javascript' in request:
        _javascript['enabled'] = bool(request['javascript'])
    if 'debug' in request:
        _debug['enabled'] = bool(request['debug'])
    return {'javascript': _javascript['enabled'], 'debug': _debug['enabled']}


def _op_info(call, request):
    with _session(call, request) as ydl:
        info = ydl.extract_info(_watch_url(request), download=False)
        return json.dumps(ydl.sanitize_info(info), ensure_ascii=False)


def _op_search(call, request):
    count = max(1, int(request.get('count', 20)))
    with _session(call, request, extract_flat='in_playlist', noplaylist=False) as ydl:
        info = ydl.extract_info(f'ytsearch{count}:{request["query"]}', download=False)
        return json.dumps(ydl.sanitize_info(info), ensure_ascii=False)


def _op_channel(call, request):
    tab = request.get('tab', 'videos')
    if tab not in ('videos', 'streams'):
        raise ValueError(f'unknown channel tab {tab!r}')
    url = f'https://www.youtube.com/channel/{request["channel_id"]}/{tab}'
    with _session(call, request, extract_flat='in_playlist', noplaylist=False,
                  playlistend=max(1, int(request.get('count', 30)))) as ydl:
        info = ydl.extract_info(url, download=False)
        return json.dumps(ydl.sanitize_info(info), ensure_ascii=False)


# yt-dlp's words when it ran but YouTube didn't take the cookies (the Mac's YTDLP.classify "auth").
_AUTH_MARKS = ('cookies are no longer valid', '--cookies for the authentication')


def _cookies_rejected(call, request):
    """A run with cookies whose warnings say YouTube didn't accept them."""
    if not request.get('cookies'):
        return False
    return any(mark in warning.lower() for warning in call.warnings for mark in _AUTH_MARKS)


def _op_flat(call, request):
    """Any flat listing (`--flat-playlist -J --playlist-end <count> <url>`): a channel tab, a playlist,
    or YouTube's own feeds (:ytrec, :ytsubs, :ythistory) with the cookies. `count` 0 lists only the
    page's own fields (`--playlist-items 0`)."""
    count = int(request.get('count', 30))
    options = {'extract_flat': 'in_playlist', 'noplaylist': False}
    if count <= 0:
        options['playlist_items'] = '0'
    else:
        options['playlistend'] = count
    with _session(call, request, **options) as ydl:
        info = ydl.extract_info(request['url'], download=False)
        return json.dumps({'info': ydl.sanitize_info(info), 'cookiesRejected': _cookies_rejected(call, request)},
                          ensure_ascii=False)


def _op_mark_watched(call, request):
    """`--simulate --mark-watched <watch url>` with the cookies: YouTube records a view, as if it was
    played there. Rejected cookies fail the call (in yt-dlp's words, so Swift classifies it)."""
    with _session(call, request, mark_watched=True, skip_download=True, simulate=True,
                  ignore_no_formats_error=True) as ydl:
        ydl.extract_info(_watch_url(request), download=False)
    if _cookies_rejected(call, request):
        call.error('ERROR: The provided YouTube account cookies are no longer valid')
        raise RuntimeError('The provided YouTube account cookies are no longer valid')
    return {'marked': True}


def _op_comments(call, request):
    limits = request.get('limits') or COMMENT_LIMITS
    with _session(call, dict(request, youtube_args={
        **(request.get('youtube_args') or {}),
        'max_comments': [str(limit) for limit in limits],
        'comment_sort': ['top'],
    }), getcomments=True, skip_download=True, ignore_no_formats_error=True) as ydl:
        info = ydl.sanitize_info(ydl.extract_info(_watch_url(request), download=False))
        result = {'comments': info.get('comments') or []}
        if info.get('comment_count') is not None:
            result['comment_count'] = info['comment_count']
        return json.dumps(result, ensure_ascii=False)


def _op_stream(call, request):
    """Where AVPlayer can play the video from: the HLS master manifest, with progressive fallbacks."""
    with _session(call, request) as ydl:
        raw = ydl.extract_info(_watch_url(request), download=False, process=False)
        formats = raw.get('formats') or []
        hls = next((f['manifest_url'] for f in formats
                    if str(f.get('protocol', '')).startswith('m3u8') and f.get('manifest_url')), None)
        ydl.params['format_sort'] = [f'res:{MAX_HEIGHT}', 'fps', 'vcodec:h264', 'acodec:m4a']
        _, pair = _select(ydl, raw, 'bv*[vcodec^=avc1][protocol^=http]+ba[ext=m4a][protocol^=http]')
        _, single = _select(ydl, raw, 'b[vcodec^=avc1][acodec!=none][ext=mp4][protocol^=http]')
        video = audio = None
        if pair and len(pair) == 2:
            video, audio = pair
        progressive = single[0] if single else None
        headers = (video or progressive or {}).get('http_headers') or {}
        return {
            'id': raw.get('id'),
            'hls': hls,
            'video': video and video.get('url'),
            'video_height': video and video.get('height'),
            'audio': audio and audio.get('url'),
            'progressive': progressive and progressive.get('url'),
            'progressive_height': progressive and progressive.get('height'),
            'headers': headers,
            'duration': raw.get('duration'),
            'is_live': bool(raw.get('is_live')),
        }


def _op_plan(call, request):
    with _session(call, request) as ydl:
        raw = ydl.extract_info(_watch_url(request), download=False, process=False)
        return _plan(ydl, raw, request.get('max_height'))


def _op_download(call, request):
    """Downloads each part (video, audio) on its own; Swift merges them with AVFoundation."""
    directory = request['dir']
    os.makedirs(directory, exist_ok=True)
    state = {'done': 0, 'current': 0, 'total': None}

    def hook(data):
        call.check()
        if data.get('status') == 'downloading':
            state['current'] = int(data.get('downloaded_bytes') or 0)
            done = state['done'] + state['current']
            total = state['total']
            if total is None:
                part_total = data.get('total_bytes') or data.get('total_bytes_estimate')
                total = state['done'] + int(part_total) if part_total else None
            call.progress({
                'downloaded': done,
                'total': total,
                'speed': data.get('speed'),
                'eta': data.get('eta'),
                'part': state['index'],
                'parts': state['count'],
            })

    with _session(call, request, progress_hooks=[hook], continuedl=True) as ydl:
        raw = ydl.extract_info(_watch_url(request), download=False, process=False)
        ids = request.get('format_ids')
        if ids:
            plan = None
            parts_info = []
            for format_id in ids:
                _, picked = _select(ydl, raw, format_id)
                if not picked:
                    raise RuntimeError(f'Format {format_id} is no longer offered')
                parts_info.append(_part(picked[0]))
        else:
            plan = _plan(ydl, raw, request.get('max_height'))
            parts_info = plan['parts']
        sizes = [part['bytes'] for part in parts_info]
        state['total'] = None if any(size is None for size in sizes) else sum(sizes)
        state['count'] = len(parts_info)
        files = []
        for index, part in enumerate(parts_info):
            state['index'] = index
            state['current'] = 0
            ydl.format_selector = ydl.build_format_selector(part['format_id'])
            ydl.params['outtmpl'] = {'default': os.path.join(directory, f'%(id)s.f{part["format_id"]}.%(ext)s')}
            info = ydl.process_ie_result(copy.deepcopy(raw), download=True)
            downloads = info.get('requested_downloads') or []
            path = downloads[0].get('filepath') if downloads else None
            if not path or not os.path.exists(path):
                raise RuntimeError('yt-dlp finished but no file was found')
            files.append(dict(part, path=path))
            state['done'] += os.path.getsize(path)
        call.progress({'downloaded': state['done'], 'total': state['done'], 'part': len(files), 'parts': len(files)}, force=True)
        return {'id': raw.get('id'), 'title': raw.get('title'), 'files': files, 'plan': plan}


def _op_ping(call, request):
    """For tests: answers without yt-dlp or the network. `sleep` checks cancellation as it waits."""
    for _ in range(int(float(request.get('sleep', 0)) * 20)):
        call.check()
        time.sleep(0.05)
    if request.get('fail'):
        call.error(f'ERROR: [test] abc: {request["fail"]}')
        raise RuntimeError(request['fail'])
    if request.get('progress'):
        call.progress({'downloaded': 1, 'total': 2}, force=True)
    return {'echo': request.get('echo'), 'thread': threading.current_thread().name}


_OPS = {
    'version': _op_version,
    'configure': _op_configure,
    'info': _op_info,
    'search': _op_search,
    'channel': _op_channel,
    'comments': _op_comments,
    'flat': _op_flat,
    'mark_watched': _op_mark_watched,
    'stream': _op_stream,
    'plan': _op_plan,
    'download': _op_download,
    'ping': _op_ping,
}
