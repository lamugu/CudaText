unit proc_drag_debug;

{$mode objfpc}{$H+}

{ Always-on drag diagnostics. Writes a flushed line log next to the exe:
  <exe_dir>\cudatext_drag_debug.log
  Also mirrors to %TEMP%\cudatext_drag_debug.log so it is easy to find. }

interface

procedure AppDragDebugReset(const AReason: string);
procedure AppDragDebugLog(const AMsg: string);
procedure AppDragDebugLogQcd(fEscapePressed: LongBool; grfKeyState: LongWord;
  const AResult: string);
function AppDragDebugLogPath: string;

implementation

uses
  SysUtils, Classes, Windows;

var
  GLogPath: string = '';
  GTempLogPath: string = '';
  GInited: boolean = false;
  GSeq: integer = 0;
  GLastQcdTick: DWORD = 0;
  GQcdCount: integer = 0;

function AppDragDebugLogPath: string;
begin
  if GLogPath='' then
    GLogPath:= IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))+
      'cudatext_drag_debug.log';
  Result:= GLogPath;
end;

procedure EnsurePaths;
var
  Tmp: array[0..MAX_PATH] of WideChar;
begin
  AppDragDebugLogPath;
  if GTempLogPath='' then
  begin
    FillChar(Tmp, SizeOf(Tmp), 0);
    GetTempPathW(MAX_PATH, Tmp);
    GTempLogPath:= UTF8Encode(WideString(Tmp))+'cudatext_drag_debug.log';
  end;
end;

procedure WriteLineTo(const APath, ALine: string);
var
  F: TextFile;
begin
  if APath='' then exit;
  try
    AssignFile(F, APath);
    {$I-}
    if FileExists(APath) then
      Append(F)
    else
      Rewrite(F);
    if IOResult<>0 then exit;
    WriteLn(F, ALine);
    Flush(F);
    CloseFile(F);
    {$I+}
  except
    // never break drag because of logging
  end;
end;

procedure AppDragDebugReset(const AReason: string);
begin
  EnsurePaths;
  try
    if FileExists(GLogPath) then
      SysUtils.DeleteFile(GLogPath);
    if FileExists(GTempLogPath) then
      SysUtils.DeleteFile(GTempLogPath);
  except
  end;
  GInited:= false;
  GSeq:= 0;
  GQcdCount:= 0;
  GLastQcdTick:= 0;
  AppDragDebugLog('RESET reason='+AReason);
end;

procedure AppDragDebugLog(const AMsg: string);
var
  Line: string;
  Cursor: TPoint;
begin
  EnsurePaths;
  Inc(GSeq);
  GetCursorPos(Cursor);
  Line:= Format(
    '%s #%d tid=%d tick=%u lbtn=%d cap=%u pos=%d,%d | %s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now),
     GSeq,
     GetCurrentThreadId,
     GetTickCount,
     Ord((GetAsyncKeyState(VK_LBUTTON) and $8000)<>0),
     GetCapture,
     Cursor.X, Cursor.Y,
     AMsg]);

  if not GInited then
  begin
    GInited:= true;
    WriteLineTo(GLogPath,
      '==== CudaText drag debug log ====');
    WriteLineTo(GLogPath,
      'exe='+ParamStr(0));
    WriteLineTo(GLogPath,
      'log='+GLogPath);
    WriteLineTo(GLogPath,
      'temp_log='+GTempLogPath);
    WriteLineTo(GTempLogPath,
      '==== CudaText drag debug log ====');
    WriteLineTo(GTempLogPath,
      'exe='+ParamStr(0));
    WriteLineTo(GTempLogPath,
      'log='+GLogPath);
  end;

  WriteLineTo(GLogPath, Line);
  WriteLineTo(GTempLogPath, Line);
  OutputDebugString(PChar('CudaDrag: '+AMsg));
end;

procedure AppDragDebugLogQcd(fEscapePressed: LongBool; grfKeyState: LongWord;
  const AResult: string);
var
  NowTick: DWORD;
begin
  Inc(GQcdCount);
  NowTick:= GetTickCount;
  // Log first 5, then at most every 200ms, and always on terminal states.
  if (GQcdCount<=5) or
     (AResult<>'S_OK') or
     (NowTick-GLastQcdTick>=200) then
  begin
    GLastQcdTick:= NowTick;
    AppDragDebugLog(Format(
      'QueryContinueDrag #%d esc=%d key=0x%x -> %s',
      [GQcdCount, Ord(fEscapePressed<>false), grfKeyState, AResult]));
  end;
end;

end.
