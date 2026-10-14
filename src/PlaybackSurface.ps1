# A single WPF window owns both photo layers and the embedded VLC video handle.
$script:PlaybackSurface = $null
$script:EmbeddedVlc = $null
$script:ReelPlayers = @()
$script:ReelSlots = @()

function Initialize-PlaybackKeyboard {
    if (-not ('MarcaVecio.PlaybackKeyboard' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace MarcaVecio {
    public sealed class TransitionForm : System.Windows.Forms.Form {
        private sealed class OwnerHandle : System.Windows.Forms.IWin32Window {
            public IntPtr Handle {get;private set;}
            public OwnerHandle(IntPtr handle){Handle=handle;}
        }
        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr window,int attribute,ref int value,int size);
        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            // Disable OS show/hide animations before this window is presented.
            int disabled=1;DwmSetWindowAttribute(Handle,3,ref disabled,sizeof(int));
        }
        protected override bool ShowWithoutActivation {get{return true;}}
        protected override System.Windows.Forms.CreateParams CreateParams {
            get {var p=base.CreateParams;p.ExStyle|=0x08000020;return p;}
        }
        public TransitionForm() {
            SetStyle(System.Windows.Forms.ControlStyles.UserPaint |
                System.Windows.Forms.ControlStyles.AllPaintingInWmPaint |
                System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer,true);
            DoubleBuffered=true;
            FormBorderStyle=System.Windows.Forms.FormBorderStyle.None;
            ShowInTaskbar=false;TopMost=true;BackColor=System.Drawing.Color.Black;
            BackgroundImageLayout=System.Windows.Forms.ImageLayout.Zoom;
            AutoScaleMode=System.Windows.Forms.AutoScaleMode.None;
        }
        public void SetFrame(byte[] pixels,int imageWidth,int imageHeight) {
            var image=new System.Drawing.Bitmap(imageWidth,imageHeight,System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            var data=image.LockBits(new System.Drawing.Rectangle(0,0,imageWidth,imageHeight),System.Drawing.Imaging.ImageLockMode.WriteOnly,System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try {Marshal.Copy(pixels,0,data.Scan0,pixels.Length);} finally {image.UnlockBits(data);}
            var previous=BackgroundImage;BackgroundImage=image;if(previous!=null)previous.Dispose();
        }
        public void ShowFrame(IntPtr owner,int x,int y,int width,int height,byte[] pixels,int imageWidth,int imageHeight) {
            SetFrame(pixels,imageWidth,imageHeight);
            Bounds=new System.Drawing.Rectangle(x,y,width,height);
            // Paint the complete frame while invisible, then reveal it atomically.
            // Bounds stay fixed throughout the uniform opacity fade.
            Opacity=0;Show(new OwnerHandle(owner));Invalidate();Update();
            NativeTransitionFade.Prepare(Handle);
        }
        public void ReleaseFrame(){Hide();var image=BackgroundImage;BackgroundImage=null;if(image!=null)image.Dispose();}
        protected override void Dispose(bool disposing){if(disposing){var image=BackgroundImage;BackgroundImage=null;if(image!=null)image.Dispose();}base.Dispose(disposing);}
    }
    public sealed class NativeTransitionFade : IDisposable {
        private readonly object sync = new object();
        private System.Threading.Timer timer;
        private IntPtr window;
        private long start;
        private int duration, generation;
        private volatile int alpha = 255;
        private volatile bool finished = true;
        private volatile bool faulted;
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr window, int index, int value);
        [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr window, uint color, byte alpha, uint flags);
        [DllImport("user32.dll")] private static extern bool GetLayeredWindowAttributes(IntPtr window, out uint color, out byte alpha, out uint flags);
        public double Opacity { get { return alpha / 255.0; } }
        public bool Finished { get { return finished; } }
        public bool Faulted { get { return faulted; } }
        public static bool Prepare(IntPtr window) {
            if (window == IntPtr.Zero) return true;
            SetWindowLong(window,-20,GetWindowLong(window,-20) | 0x80000);
            return SetLayeredWindowAttributes(window,0,255,2);
        }
        public static int ReadAlpha(IntPtr window) { uint color,flags; byte value; return GetLayeredWindowAttributes(window,out color,out value,out flags) ? value : -1; }
        public void Start(IntPtr window, int duration) {
            lock(sync) {
                StopLocked(); this.window=window; this.duration=Math.Max(1,duration);
                alpha=255; finished=false; faulted=false; start=Stopwatch.GetTimestamp();
                int token=generation;
                timer=new System.Threading.Timer(_ => Tick(token),null,0,16);
            }
        }
        private void Tick(int token) {
            lock(sync) {
                if(token!=generation || finished) return;
                double elapsed=(Stopwatch.GetTimestamp()-start)*1000.0/Stopwatch.Frequency;
                alpha=(int)Math.Round(255*Math.Max(0,1-elapsed/duration));
                if(window!=IntPtr.Zero && !SetLayeredWindowAttributes(window,0,(byte)alpha,2)) faulted=true;
                if(elapsed>=duration || faulted) { finished=true; timer.Dispose(); timer=null; }
            }
        }
        private void StopLocked() { generation++; if(timer!=null){timer.Dispose();timer=null;} finished=true; }
        public void Stop() { lock(sync){StopLocked();} }
        public void Dispose() { Stop(); }
    }
    public static class PlaybackKeyboard {
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll",SetLastError=true)] private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll",SetLastError=true)] private static extern bool UnregisterHotKey(IntPtr window, int id);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr bitmap);
        public static void RegisterStop(IntPtr window, int id) {
            // Ctrl + Alt + S, registered only while the fullscreen player exists.
            if (!RegisterHotKey(window,id,0x4003,0x53)) {
                int error = Marshal.GetLastWin32Error();
                string message = error == 1409 ? "Ctrl+Alt+S gia in uso. Chiudi l'altra applicazione che usa questa scorciatoia e riprova." :
                    error == 1459 ? "La scorciatoia globale richiede una sessione Windows interattiva. Avvia l'app dal desktop Windows." :
                    "Impossibile attivare Ctrl+Alt+S. Errore Windows: " + error;
                throw new System.ComponentModel.Win32Exception(error,message);
            }
        }
        public static void UnregisterStop(IntPtr window, int id) { UnregisterHotKey(window,id); }
        public static void BringToForeground(IntPtr window) { SetForegroundWindow(window); }
        public static bool EscapePressed() {
            uint foregroundProcess;
            GetWindowThreadProcessId(GetForegroundWindow(),out foregroundProcess);
            // VLC's embedded child may own keyboard focus and bypass WPF key events.
            // Only handle Escape when this app owns the foreground window.
            return foregroundProcess == (uint)Process.GetCurrentProcess().Id && (GetAsyncKeyState(0x1B) & 0x8000) != 0;
        }
    }
}
'@
    }
}

function Test-PlaybackEscapePressed { return [MarcaVecio.PlaybackKeyboard]::EscapePressed() }

function Invoke-PlaybackStopShortcut {
    Stop-Playback
    if (Get-Command Show-ConfigurationWindow -ErrorAction SilentlyContinue) { Show-ConfigurationWindow }
}

function Register-PlaybackStopShortcut {
    $surface = $script:PlaybackSurface
    if ($surface.hotkeyRegistered) { return }
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($surface.window)).EnsureHandle()
    $source = [Windows.Interop.HwndSource]::FromHwnd($hwnd)
    $hook = [Windows.Interop.HwndSourceHook]{
        param([IntPtr]$windowHandle,[int]$message,[IntPtr]$wParam,[IntPtr]$lParam,[ref]$handled)
        if ($message -eq 0x0312 -and $script:PlaybackSurface -and $wParam.ToInt32() -eq $script:PlaybackSurface.hotkeyId) {
            $handled.Value = $true
            Invoke-PlaybackStopShortcut
        }
        return [IntPtr]::Zero
    }
    $source.AddHook($hook)
    $surface.hotkeySource = $source
    $surface.hotkeyHook = $hook
    $surface.hotkeyHandle = $hwnd
    [MarcaVecio.PlaybackKeyboard]::RegisterStop($hwnd,$surface.hotkeyId)
    $surface.hotkeyRegistered = $true
}

function Update-PlaybackKeyboard {
    if ($script:PlaybackSurface -and -not $script:PlaybackSurface.disposing -and (Test-PlaybackEscapePressed)) { Invoke-PlaybackStopShortcut }
}

function Initialize-EmbeddedVlc([string]$VlcPath, [string[]]$Arguments = @()) {
    if (-not ('MarcaVecio.NativeVlc' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
namespace MarcaVecio {
    public sealed class NativeVlc : IDisposable {
        private IntPtr instance, player, currentMedia;
        private readonly object stopSync = new object();
        private System.Threading.Tasks.Task stopTask;
        [StructLayout(LayoutKind.Sequential)] private struct MediaStats {
            public int readBytes; public float inputBitrate; public int demuxReadBytes; public float demuxBitrate;
            public int demuxCorrupted, demuxDiscontinuity, decodedVideo, decodedAudio, displayedPictures, lostPictures;
            public int playedAudioBuffers, lostAudioBuffers, sentPackets, sentBytes; public float sendBitrate;
        }
        private static string loadedDirectory;
        public IntPtr PlayerHandle { get { return player; } }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool SetDllDirectory(string directory);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr LoadLibrary(string path);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr libvlc_new(int count, [MarshalAs(UnmanagedType.LPArray,ArraySubType=UnmanagedType.LPStr)] string[] arguments);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_release(IntPtr instance);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr libvlc_media_player_new(IntPtr instance);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_media_player_release(IntPtr player);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr libvlc_media_new_path(IntPtr instance, byte[] path);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_media_release(IntPtr media);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern int libvlc_media_get_stats(IntPtr media, out MediaStats stats);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_media_add_option(IntPtr media, byte[] option);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_media_player_set_media(IntPtr player, IntPtr media);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_media_player_set_hwnd(IntPtr player, IntPtr handle);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_video_set_mouse_input(IntPtr player, uint enable);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_video_set_key_input(IntPtr player, uint enable);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern int libvlc_media_player_play(IntPtr player);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_media_player_stop(IntPtr player);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern int libvlc_media_player_get_state(IntPtr player);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern long libvlc_media_player_get_length(IntPtr player);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern long libvlc_media_player_get_time(IntPtr player);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern int libvlc_video_get_size(IntPtr player, uint index, out uint width, out uint height);
        [DllImport("libvlc.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void libvlc_audio_set_mute(IntPtr player, int mute);
        public NativeVlc(string directory, string[] arguments) {
            directory = Path.GetFullPath(directory);
            if (loadedDirectory != null && !String.Equals(loadedDirectory, directory, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Percorso VLC cambiato: riavvia l'app per caricare la nuova libreria.");
            if (loadedDirectory == null) {
                if (!File.Exists(Path.Combine(directory,"libvlc.dll"))) throw new FileNotFoundException("libvlc.dll non trovata accanto a vlc.exe.");
                if (!SetDllDirectory(directory) || LoadLibrary(Path.Combine(directory,"libvlc.dll")) == IntPtr.Zero)
                    throw new InvalidOperationException("Impossibile caricare VLC. Installa VLC a 64 bit per questa app.");
                loadedDirectory = directory;
            }
            instance = libvlc_new(arguments.Length, arguments);
            if (instance == IntPtr.Zero) throw new InvalidOperationException("Inizializzazione VLC non riuscita.");
            player = libvlc_media_player_new(instance);
            if (player == IntPtr.Zero) { libvlc_release(instance); instance = IntPtr.Zero; throw new InvalidOperationException("Player VLC non disponibile."); }
        }
        public void Play(string path, IntPtr window) { PlayCore(path,window,false); }
        public void PlayLooped(string path, IntPtr window) { PlayCore(path,window,true); }
        private void PlayCore(string path, IntPtr window, bool loop) {
            Stop();
            IntPtr media = libvlc_media_new_path(instance, Encoding.UTF8.GetBytes(path + "\0"));
            if (media == IntPtr.Zero) throw new InvalidOperationException("Video non leggibile.");
            currentMedia = media;
            if (loop) libvlc_media_add_option(media,Encoding.UTF8.GetBytes(":input-repeat=65535\0"));
            libvlc_media_player_set_media(player,media);
            libvlc_media_player_set_hwnd(player,window);
            libvlc_video_set_mouse_input(player,0); libvlc_video_set_key_input(player,0);
            if (libvlc_media_player_play(player) != 0) throw new InvalidOperationException("Avvio video non riuscito.");
        }
        public int State { get { return player == IntPtr.Zero ? 5 : libvlc_media_player_get_state(player); } }
        public long Length { get { return player == IntPtr.Zero ? 0 : libvlc_media_player_get_length(player); } }
        public long Time { get { return player == IntPtr.Zero ? 0 : libvlc_media_player_get_time(player); } }
        public bool FrameReady(bool headless) {
            MediaStats stats;
            if(currentMedia==IntPtr.Zero) return false;
            if(libvlc_media_get_stats(currentMedia,out stats)!=0 && stats.decodedVideo>0) return true;
            uint width,height;
            return Time>0 && libvlc_video_get_size(player,0,out width,out height)==0 && width>0 && height>0;
        }
        public void SetMuted(bool muted) { libvlc_audio_set_mute(player,muted ? 1 : 0); }
        public void Stop() {
            if (player != IntPtr.Zero) libvlc_media_player_stop(player);
            if (currentMedia != IntPtr.Zero) { libvlc_media_release(currentMedia); currentMedia = IntPtr.Zero; }
        }
        public System.Threading.Tasks.Task BeginStop() {
            lock(stopSync) {
                if(stopTask==null || stopTask.IsCompleted) stopTask=System.Threading.Tasks.Task.Run((Action)Stop);
                return stopTask;
            }
        }
        public void DisposeAfterStop() { BeginStop().ContinueWith(_ => Dispose()); }
        public void Dispose() {
            if (player != IntPtr.Zero) { Stop(); libvlc_media_player_release(player); player = IntPtr.Zero; }
            if (instance != IntPtr.Zero) { libvlc_release(instance); instance = IntPtr.Zero; }
        }
    }
}
'@
    }
    $options = @('--no-video-title-show','--no-osd','--no-video-deco','--quiet') + $Arguments
    $script:PlaybackVlcDirectory = Split-Path -Parent $VlcPath
    $script:PlaybackVlcOptions = $options
    $script:EmbeddedVlc = New-Object MarcaVecio.NativeVlc((Split-Path -Parent $VlcPath), ([string[]]$options))
}

function New-PlaybackSurface([bool]$Headless = $false) {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,WindowsFormsIntegration
    Initialize-PlaybackKeyboard
    $window = New-Object Windows.Window
    $window.Title = 'Marca Vecio Stream - Schermo'
    $window.WindowStyle = [Windows.WindowStyle]::None
    $window.ResizeMode = [Windows.ResizeMode]::NoResize
    $window.Background = [Windows.Media.Brushes]::Black
    $window.Topmost = -not $Headless
    $window.ShowActivated = -not $Headless
    $window.ShowInTaskbar = $false
    $window.Left = 0; $window.Top = 0
    $window.Width = [Windows.SystemParameters]::PrimaryScreenWidth
    $window.Height = [Windows.SystemParameters]::PrimaryScreenHeight
    if ($Headless) { $window.Width = 320; $window.Height = 180 }
    $grid = New-Object Windows.Controls.Grid
    $grid.Background = [Windows.Media.Brushes]::Black
    $layers = @()
    foreach ($index in @(0,1)) {
        $image = New-Object Windows.Controls.Image
        $image.Stretch = [Windows.Media.Stretch]::Uniform
        $image.Opacity = 0
        $grid.Children.Add($image) | Out-Null
        $layers += $image
    }
    $panel = New-Object Windows.Forms.Panel
    $panel.BackColor = [Drawing.Color]::Black
    $panel.Dock = [Windows.Forms.DockStyle]::Fill
    $hostControl = New-Object Windows.Forms.Integration.WindowsFormsHost
    $hostControl.Child = $panel
    $hostControl.Visibility = [Windows.Visibility]::Collapsed
    $grid.Children.Add($hostControl) | Out-Null
    $window.Content = $grid
    $reelCanvas = New-Object Windows.Controls.Canvas
    $reelCanvas.Background = [Windows.Media.Brushes]::Black
    $reelCanvas.Visibility = [Windows.Visibility]::Collapsed
    [Windows.Controls.Panel]::SetZIndex($reelCanvas,3)
    $grid.Children.Add($reelCanvas) | Out-Null
    $reelBackground = New-Object Windows.Controls.Image
    $reelBackground.Stretch = [Windows.Media.Stretch]::Fill
    $reelCanvas.Children.Add($reelBackground) | Out-Null
    $reelHosts = @(); $reelPanels = @()
    for ($i=0; $i -lt 3; $i++) {
        $reelPanel = New-Object Windows.Forms.Panel
        $reelPanel.BackColor = [Drawing.Color]::Black
        $reelPanel.Add_KeyDown({ param($sender,$event) if ($event.KeyCode -eq [Windows.Forms.Keys]::Escape) { $event.Handled = $true; Invoke-PlaybackStopShortcut } })
        $reelHost = New-Object Windows.Forms.Integration.WindowsFormsHost
        $reelHost.Child = $reelPanel
        $reelCanvas.Children.Add($reelHost) | Out-Null
        $reelHosts += $reelHost; $reelPanels += $reelPanel
    }
    $transitionCover = New-Object Windows.Controls.Image
    $transitionCover.Stretch = [Windows.Media.Stretch]::Uniform
    $transitionCover.Visibility = [Windows.Visibility]::Collapsed
    # One static native bitmap, blended by the window compositor rather than a
    # per-pixel transparent fullscreen WPF surface rendered at every frame.
    $transitionWindow = New-Object MarcaVecio.TransitionForm
    $transitionWindow.Add_KeyDown({ param($sender,$event) if ($event.KeyCode -eq [Windows.Forms.Keys]::Escape) { $event.Handled = $true; Invoke-PlaybackStopShortcut } })
    $escapeTimer = New-Object Windows.Threading.DispatcherTimer
    $escapeTimer.Interval = [TimeSpan]::FromMilliseconds(20)
    $escapeTimer.Add_Tick({ Update-PlaybackTransition; Update-PlaybackKeyboard })
    $script:PlaybackSurface = [pscustomobject]@{ window = $window; grid = $grid; layers = $layers; front = 0; videoHost = $hostControl;
        videoPanel = $panel; reelCanvas = $reelCanvas; reelBackground = $reelBackground; reelHosts = $reelHosts; reelPanels = $reelPanels;
        transitionCover = $transitionCover; transitionWindow = $transitionWindow; transitionFading = $false;
        transitionFade = (New-Object MarcaVecio.NativeTransitionFade); transitionStarted = [datetime]::MinValue;
        reelPresented = $false; videoPresented = $false; videoEndingFrame = $null;
        headless = $Headless; transitionMilliseconds = 450; transitionCount = 0; disposing = $false; closed = $false; escapeTimer = $escapeTimer;
        hotkeyId = 0x4D56; hotkeyRegistered = $false; hotkeySource = $null; hotkeyHook = $null; hotkeyHandle = [IntPtr]::Zero }
    $window.Add_PreviewKeyDown({ param($sender,$event) if ($event.Key -eq [Windows.Input.Key]::Escape) { $event.Handled = $true; Invoke-PlaybackStopShortcut } })
    $panel.Add_KeyDown({ param($sender,$event) if ($event.KeyCode -eq [Windows.Forms.Keys]::Escape) { $event.Handled = $true; $event.SuppressKeyPress = $true; Invoke-PlaybackStopShortcut } })
    $window.Add_Closed({ param($sender,$event)
        if ($script:PlaybackSurface -and [object]::ReferenceEquals($sender,$script:PlaybackSurface.window)) {
            $script:PlaybackSurface.closed = $true
            if (-not $script:PlaybackSurface.disposing) { Stop-Playback }
        }
    })
    if (-not $Headless) {
        # Register before showing fullscreen: never start a player without its exit shortcut.
        Register-PlaybackStopShortcut
        $window.Show()
        $window.Activate() | Out-Null
        $window.Focus() | Out-Null
        $escapeTimer.Start()
    }
    $grid.Measure((New-Object Windows.Size($window.Width,$window.Height)))
    $grid.Arrange((New-Object Windows.Rect(0,0,$window.Width,$window.Height)))
    $window.UpdateLayout()
    $grid.Add_SizeChanged({ Update-ReelLayout })
    Update-ReelLayout
}

function Update-ReelLayout {
    $surface = $script:PlaybackSurface
    if (-not $surface) { return }
    $width = $surface.grid.ActualWidth; $height = $surface.grid.ActualHeight
    $scale = [math]::Min($width/960,$height/540)
    $left = ($width-960*$scale)/2; $top = ($height-540*$scale)/2
    $surface.reelBackground.Width = 960*$scale; $surface.reelBackground.Height = 540*$scale
    [Windows.Controls.Canvas]::SetLeft($surface.reelBackground,$left)
    [Windows.Controls.Canvas]::SetTop($surface.reelBackground,$top)
    $rects = @(@(57,52,245.25,436),@(327,0,303.75,540),@(658,52,245.25,436))
    for ($i=0; $i -lt 3; $i++) {
        $hostControl = $surface.reelHosts[$i]; $rect = $rects[$i]
        $hostControl.Width = $rect[2]*$scale; $hostControl.Height = $rect[3]*$scale
        [Windows.Controls.Canvas]::SetLeft($hostControl,($left+$rect[0]*$scale))
        [Windows.Controls.Canvas]::SetTop($hostControl,($top+$rect[1]*$scale))
    }
}

function Stop-NativePlayer([object]$Player,[int]$TimeoutMilliseconds = 5000) {
    $task = $Player.BeginStop()
    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while (-not $task.IsCompleted) {
        if ([datetime]::UtcNow -ge $deadline) {
            $error = New-Object InvalidOperationException('VLC non risponde durante il cambio del contenuto.')
            $error.Data['PlaybackStopTimeout']=$true
            throw $error
        }
        # VLC may send window messages while destroying its output. Keep the UI
        # pumping instead of waiting synchronously on the decoder's stop call.
        $frame = New-Object Windows.Threading.DispatcherFrame
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(20)
        $timer.Add_Tick({ $timer.Stop(); $frame.Continue = $false })
        $timer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    $task.GetAwaiter().GetResult()
}

function Release-NativePlayer([object]$Player) {
    if ($Player.PSObject.Methods['BeginStop']) {
        $task = $Player.BeginStop()
        if (-not $task.IsCompleted) { $Player.DisposeAfterStop(); return $task }
    }
    $Player.Dispose()
    if (Get-Variable task -Scope Local -ErrorAction SilentlyContinue) { return $task }
}

function Stop-PlaybackReels {
    if ($script:PlaybackSurface) {
        $wasVisible = $script:PlaybackSurface.reelCanvas.Visibility -eq [Windows.Visibility]::Visible
        $script:PlaybackSurface.reelCanvas.Visibility = [Windows.Visibility]::Collapsed
        foreach ($reelHost in $script:PlaybackSurface.reelHosts) { $reelHost.Visibility = [Windows.Visibility]::Hidden }
        if ($wasVisible) { $script:PlaybackSurface.window.UpdateLayout() }
    }
    foreach ($player in $script:ReelPlayers) { Stop-NativePlayer $player }
    $script:ReelSlots = @()
    if ($script:PlaybackSurface) { $script:PlaybackSurface.reelCanvas.Visibility = [Windows.Visibility]::Collapsed }
}

function Hold-PlaybackVisual([bool]$CaptureOnly = $false) {
    $surface = $script:PlaybackSurface
    if (-not $surface -or (-not $CaptureOnly -and $surface.transitionCover.Visibility -eq [Windows.Visibility]::Visible)) { return }
    $hasPhoto = @($surface.layers | Where-Object { $_.Source }).Count -gt 0
    $hasVideo = $surface.videoHost.Visibility -eq [Windows.Visibility]::Visible -or $surface.reelCanvas.Visibility -eq [Windows.Visibility]::Visible
    if (-not $hasPhoto -and -not $hasVideo) { return }
    try {
        if (-not $CaptureOnly -and $surface.videoHost.Visibility -eq [Windows.Visibility]::Visible -and $surface.videoEndingFrame) {
            $frame = $surface.videoEndingFrame
        } elseif ($hasVideo -and -not $surface.headless) {
            # Capture only this fullscreen player's displayed pixels, in memory.
            $point = $surface.window.PointToScreen((New-Object Windows.Point(0,0)))
            $transform = [Windows.PresentationSource]::FromVisual($surface.window).CompositionTarget.TransformToDevice
            $width = [int][math]::Ceiling($surface.grid.ActualWidth*$transform.M11)
            $height = [int][math]::Ceiling($surface.grid.ActualHeight*$transform.M22)
            $screenBitmap = New-Object Drawing.Bitmap($width,$height)
            $graphics = [Drawing.Graphics]::FromImage($screenBitmap)
            $handle = [IntPtr]::Zero
            try {
                $graphics.CopyFromScreen([int]$point.X,[int]$point.Y,0,0,(New-Object Drawing.Size($width,$height)))
                $handle = $screenBitmap.GetHbitmap()
                $frame = [Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap($handle,[IntPtr]::Zero,[Windows.Int32Rect]::Empty,[Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                $frame.Freeze()
            } finally {
                if ($handle -ne [IntPtr]::Zero) { [MarcaVecio.PlaybackKeyboard]::DeleteObject($handle) | Out-Null }
                $graphics.Dispose(); $screenBitmap.Dispose()
            }
        } elseif ($hasPhoto -and -not $hasVideo) {
            $frame = $surface.layers[$surface.front].Source
        } else {
            $frame = New-Object Windows.Media.Imaging.RenderTargetBitmap([int][math]::Max(1,$surface.grid.ActualWidth),[int][math]::Max(1,$surface.grid.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $frame.Render($surface.grid); $frame.Freeze()
        }
        if ($CaptureOnly) { return $frame }
        $surface.transitionCover.Source = $frame
        Show-PlaybackCover
    } catch {
        # Preserve the previous photo if screen capture is unavailable.
        if ($hasPhoto) {
            if ($CaptureOnly) { return $surface.layers[$surface.front].Source }
            $surface.transitionCover.Source = $surface.layers[$surface.front].Source
            Show-PlaybackCover
        }
    }
}

function Show-PlaybackCover {
    $surface = $script:PlaybackSurface
    $surface.transitionFading = $false
    $surface.transitionFade.Stop()
    $surface.transitionCover.Visibility = [Windows.Visibility]::Visible
    if (-not $surface.headless) {
        $bitmap = New-Object Windows.Media.Imaging.FormatConvertedBitmap($surface.transitionCover.Source,[Windows.Media.PixelFormats]::Pbgra32,$null,0)
        $stride = $bitmap.PixelWidth*4
        $pixels = New-Object byte[] ($stride*$bitmap.PixelHeight)
        $bitmap.CopyPixels($pixels,$stride,0)
        $point = $surface.window.PointToScreen((New-Object Windows.Point(0,0)))
        $transform = [Windows.PresentationSource]::FromVisual($surface.window).CompositionTarget.TransformToDevice
        $owner = (New-Object Windows.Interop.WindowInteropHelper($surface.window)).Handle
        $surface.transitionWindow.ShowFrame($owner,[int]$point.X,[int]$point.Y,[int]($surface.grid.ActualWidth*$transform.M11),[int]($surface.grid.ActualHeight*$transform.M22),$pixels,$bitmap.PixelWidth,$bitmap.PixelHeight)
    }
}

function Clear-PlaybackCover {
    $script:PlaybackSurface.transitionFading = $false
    $script:PlaybackSurface.transitionFade.Stop()
    $script:PlaybackSurface.transitionWindow.ReleaseFrame()
    $script:PlaybackSurface.transitionCover.Visibility = [Windows.Visibility]::Collapsed
    $script:PlaybackSurface.transitionCover.Source = $null
}

function Start-PlaybackDissolve {
    $surface = $script:PlaybackSurface
    if ($surface.transitionFading -or $surface.transitionCover.Visibility -ne [Windows.Visibility]::Visible) { return }
    $surface.transitionFading = $true
    $surface.transitionCount++
    $surface.transitionStarted = [datetime]::UtcNow
    $handle = if ($surface.headless) { [IntPtr]::Zero } else { $surface.transitionWindow.Handle }
    $surface.transitionFade.Start($handle,$surface.transitionMilliseconds)
}

function Update-PlaybackTransition {
    $surface = $script:PlaybackSurface
    if (-not $surface -or $surface.disposing -or -not $surface.transitionFading) { return }
    if ($surface.transitionFade.Finished -or ([datetime]::UtcNow-$surface.transitionStarted).TotalMilliseconds -ge ($surface.transitionMilliseconds+250)) { Clear-PlaybackCover }
}

function Present-PlaybackVideo {
    $surface = $script:PlaybackSurface
    if ($surface.videoPresented) { return }
    $surface.videoPresented = $true
    $surface.videoHost.Visibility = [Windows.Visibility]::Visible
    Start-PlaybackDissolve
}

function Present-PlaybackReels {
    $surface = $script:PlaybackSurface
    # Prepare the children under the hidden parent, then reveal the whole scene.
    for ($i=0; $i -lt $script:ReelSlots.Count; $i++) {
        $surface.reelHosts[$i].Visibility = if ($script:ReelSlots[$i].failed) { [Windows.Visibility]::Hidden } else { [Windows.Visibility]::Visible }
    }
    $surface.reelCanvas.Visibility = [Windows.Visibility]::Visible
    $surface.videoHost.Visibility = [Windows.Visibility]::Collapsed
    foreach ($layer in $surface.layers) { $layer.BeginAnimation([Windows.UIElement]::OpacityProperty,$null); $layer.Source = $null; $layer.Opacity = 0 }
    Start-PlaybackDissolve
    if (-not $surface.reelPresented) { $surface.reelPresented = $true; $script:PlaybackStarted = [datetime]::UtcNow }
}

function Show-PlaybackReels($Members, [string]$Background) {
    Hold-PlaybackVisual
    Stop-PlaybackReels
    $surface = $script:PlaybackSurface
    if (-not $surface) { return }
    $surface.reelPresented = $false
    $surface.videoEndingFrame = $null
    if ($script:ReelPlayers.Count -eq 0) {
        for ($i=0; $i -lt 3; $i++) {
            $options = [string[]]($script:PlaybackVlcOptions + @('--no-audio'))
            $script:ReelPlayers += New-Object MarcaVecio.NativeVlc($script:PlaybackVlcDirectory,$options)
        }
    }
    $surface.reelBackground.Source = $null
    $root = Get-Variable AppRoot -ValueOnly -ErrorAction SilentlyContinue
    $fallback = if ($root) { Join-Path $root 'assets\reel-background.jpg' } else { '' }
    foreach ($backgroundPath in @(@($Background,$fallback) | Select-Object -Unique)) {
        if (-not $backgroundPath -or -not [IO.File]::Exists($backgroundPath)) { continue }
        $stream = $null
        try {
            $stream = [IO.MemoryStream]::new([IO.File]::ReadAllBytes($backgroundPath))
            $bitmap = New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit(); $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.StreamSource = $stream
            $bitmap.EndInit(); $bitmap.Freeze(); $surface.reelBackground.Source = $bitmap
            break
        } catch { Set-PlaybackNotice ('Sfondo reel non leggibile: ' + [IO.Path]::GetFileName($backgroundPath) + '. ' + $_.Exception.Message) $true }
        finally { if ($stream) { $stream.Dispose() } }
    }
    $surface.videoHost.Visibility = [Windows.Visibility]::Collapsed
    $surface.reelCanvas.Visibility = [Windows.Visibility]::Hidden
    Update-ReelLayout
    $surface.window.UpdateLayout()
    for ($i=0; $i -lt 3; $i++) {
        $surface.reelHosts[$i].Visibility = [Windows.Visibility]::Hidden
        $script:ReelPlayers[$i].PlayLooped($Members[$i].fullName,$surface.reelPanels[$i].Handle)
        $script:ReelPlayers[$i].SetMuted($true)
        $script:ReelSlots += [pscustomobject]@{ item = $Members[$i]; failed = $false; sawPlaying = $false; frameReady = $false; started = [datetime]::UtcNow; lastTime = 0; loops = 0 }
    }
}

function Show-PlaybackSlide([string]$Path) {
    Stop-PlaybackReels
    $surface = $script:PlaybackSurface
    if (-not $surface) { return }
    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
    $bitmap.UriSource = New-Object uri($Path)
    $bitmap.EndInit(); $bitmap.Freeze()
    # Finish any previous animation before reusing its layer; no file remains locked.
    foreach ($layer in $surface.layers) {
        $opacity = $layer.Opacity
        $layer.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
        $layer.Opacity = $opacity
    }
    if ($surface.videoHost.Visibility -eq [Windows.Visibility]::Visible) {
        foreach ($layer in $surface.layers) { $layer.Source = $null; $layer.Opacity = 0 }
    }
    $oldLayer = $surface.layers[$surface.front]
    $surface.front = 1 - $surface.front
    $newLayer = $surface.layers[$surface.front]
    $newLayer.Source = $bitmap
    $newLayer.Opacity = 1
    [Windows.Controls.Panel]::SetZIndex($oldLayer,0)
    [Windows.Controls.Panel]::SetZIndex($newLayer,1)
    $surface.videoHost.Visibility = [Windows.Visibility]::Collapsed
    if ($surface.transitionCover.Visibility -eq [Windows.Visibility]::Visible) {
        $oldLayer.Opacity = 0
        Start-PlaybackDissolve
    } elseif ($oldLayer.Source) {
        $oldLayer.Opacity = 1
        $animation = New-Object Windows.Media.Animation.DoubleAnimation
        $animation.From = 0; $animation.To = 1
        $animation.Duration = New-Object Windows.Duration([TimeSpan]::FromMilliseconds($surface.transitionMilliseconds))
        $animation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
        $newLayer.BeginAnimation([Windows.UIElement]::OpacityProperty,$animation)
        $surface.transitionCount++
    } else { $oldLayer.Opacity = 0 }
    $surface.videoEndingFrame = $null
}

function Show-PlaybackVideo([string]$Path) {
    Stop-PlaybackReels
    $surface = $script:PlaybackSurface
    if (-not $surface) { return }
    $surface.videoPresented = $false
    $surface.videoEndingFrame = $null
    $surface.videoHost.Visibility = [Windows.Visibility]::Hidden
    $surface.window.UpdateLayout()
    # The same child HWND is retained for every video; no standalone VLC window.
    $script:EmbeddedVlc.Play($Path, $surface.videoPanel.Handle)
}

function Close-PlaybackSurface {
    $pendingTasks = @()
    if ($script:PlaybackSurface) {
        $script:PlaybackSurface.disposing = $true
        $script:PlaybackSurface.transitionFade.Stop()
        $script:PlaybackSurface.transitionWindow.Hide()
        if (-not $script:PlaybackSurface.headless -and -not $script:PlaybackSurface.closed) { $script:PlaybackSurface.window.Hide() }
    }
    foreach ($player in $script:ReelPlayers) { $pendingTasks += @(Release-NativePlayer $player) }
    $script:ReelPlayers = @(); $script:ReelSlots = @()
    if ($script:PlaybackSurface) {
        $script:PlaybackSurface.disposing = $true
        $script:PlaybackSurface.escapeTimer.Stop()
        $surface = $script:PlaybackSurface
        if ($surface.hotkeyRegistered) {
            [MarcaVecio.PlaybackKeyboard]::UnregisterStop($surface.hotkeyHandle,$surface.hotkeyId)
            $surface.hotkeyRegistered = $false
        }
        if ($surface.hotkeySource -and $surface.hotkeyHook) {
            if (-not $surface.hotkeySource.IsDisposed) { $surface.hotkeySource.RemoveHook($surface.hotkeyHook) }
            $surface.hotkeyHook = $null
        }
    }
    if ($script:EmbeddedVlc) { $pendingTasks += @(Release-NativePlayer $script:EmbeddedVlc); $script:EmbeddedVlc = $null }
    if ($script:PlaybackSurface) {
        $surface = $script:PlaybackSurface
        $surface.disposing = $true
        $surface.transitionFade.Dispose()
        $surface.transitionWindow.Close()
        $surface.transitionWindow.Dispose()
        $script:PlaybackSurface = $null
        if (@($pendingTasks | Where-Object { -not $_.IsCompleted }).Count -gt 0) {
            # Hidden HWNDs stay alive until VLC has finished destroying its
            # output. Closing an old window must never stop a new playback.
            $cleanupTimer = New-Object Windows.Threading.DispatcherTimer
            $cleanupTimer.Interval = [TimeSpan]::FromMilliseconds(30)
            $cleanupTimer.Tag = [pscustomobject]@{ surface=$surface; tasks=$pendingTasks }
            $cleanupTimer.Add_Tick({ param($sender,$event)
                $state = $sender.Tag
                if (@($state.tasks | Where-Object { -not $_.IsCompleted }).Count -eq 0) {
                    $sender.Stop(); $sender.Tag=$null
                    Close-DetachedPlaybackSurface $state.surface
                }
            })
            $cleanupTimer.Start()
        } else { Close-DetachedPlaybackSurface $surface }
    }
}

function Close-DetachedPlaybackSurface($Surface) {
    if (-not $Surface.closed) { $Surface.window.Close(); $Surface.closed=$true }
    $Surface.videoHost.Dispose(); $Surface.videoPanel.Dispose()
    foreach ($reelHost in $Surface.reelHosts) { $reelHost.Dispose() }
    foreach ($reelPanel in $Surface.reelPanels) { $reelPanel.Dispose() }
}
