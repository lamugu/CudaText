unit proc_windows_dragfiles;



{$mode objfpc}{$H+}



interface



function AppDragFiles(const AFileNames: string;

  out ACanceledByEscape: boolean): boolean;



implementation



uses

  Windows, ActiveX, ShlObj, SysUtils, Classes, Controls, LazFileUtils,

  proc_drag_debug;



const

  cFileSeparator = #1;

  cCF_HDROP = 15;

  cDVASPECT_CONTENT = 1;

  cDRAGDROP_S_DROP = HRESULT($00040100);

  cDRAGDROP_S_CANCEL = HRESULT($00040101);

  cDRAGDROP_S_USEDEFAULTCURSORS = HRESULT($00040102);

  cDV_E_FORMATETC = HRESULT($80040064);

  cOLE_E_ADVISENOTSUPPORTED = HRESULT($80040003);

  cDATA_S_SAMEFORMATETC = HRESULT($00040130);



type

  TUnicodeFileArray = array of UnicodeString;



  // FPC's ShlObj declares SHCreateStdEnumFmtEtc with an open-array param,

  // which passes an extra High() dword and corrupts the stdcall stack → AV

  // inside DoDragDrop as soon as EnumFormatEtc is queried. Use the real ABI.

  TEnumFormatEtc = class(TInterfacedObject, IEnumFORMATETC)

  private

    FIndex: integer;

    FFmt: FORMATETC;

  public

    constructor Create(const AFmt: FORMATETC; AIndex: integer=0);

    function Next(celt: ULONG; out elt: FORMATETC;

      pceltFetched: PULONG): HRESULT; stdcall;

    function Skip(celt: ULONG): HRESULT; stdcall;

    function Reset: HRESULT; stdcall;

    function Clone(out enumFormatEtc: IEnumFORMATETC): HRESULT; stdcall;

  end;



  TFileDataObject = class(TInterfacedObject, IDataObject)

  private

    FFiles: array of UnicodeString;

    function CreateDropHandle: HGLOBAL;

    function MakeFormatEtc: FORMATETC;

  public

    constructor Create(const AFiles: array of UnicodeString);

    function GetData(const formatetcIn: FORMATETC;

      out medium: STGMEDIUM): HRESULT; stdcall;

    function GetDataHere(const pformatetc: FORMATETC;

      out medium: STGMEDIUM): HRESULT; stdcall;

    function QueryGetData(const pformatetc: FORMATETC): HRESULT; stdcall;

    function GetCanonicalFormatEtc(const pformatetcIn: FORMATETC;

      out pformatetcOut: FORMATETC): HRESULT; stdcall;

    function SetData(const pformatetc: FORMATETC; var medium: STGMEDIUM;

      FRelease: BOOL): HRESULT; stdcall;

    function EnumFormatEtc(dwDirection: DWORD;

      out enumformatetcpara: IEnumFORMATETC): HRESULT; stdcall;

    function DAdvise(const formatetc: FORMATETC; advf: DWORD;

      const AdvSink: IAdviseSink; out dwConnection: DWORD): HRESULT; stdcall;

    function DUnadvise(dwconnection: DWORD): HRESULT; stdcall;

    function EnumDAdvise(out enumAdvise: IEnumStatData): HRESULT; stdcall;

  end;



  TFileDropSource = class(TInterfacedObject, IDropSource)

  private

    FCanceledByEscape: boolean;

    FGiveFeedbackCount: integer;

  public

    property CanceledByEscape: boolean read FCanceledByEscape;

    function QueryContinueDrag(fEscapePressed: BOOL;

      grfKeyState: DWORD): HRESULT; stdcall;

    function GiveFeedback(dwEffect: DWORD): HRESULT; stdcall;

  end;



{ TEnumFormatEtc }



constructor TEnumFormatEtc.Create(const AFmt: FORMATETC; AIndex: integer);

begin

  inherited Create;

  FFmt:= AFmt;

  FIndex:= AIndex;

end;



function TEnumFormatEtc.Next(celt: ULONG; out elt: FORMATETC;

  pceltFetched: PULONG): HRESULT; stdcall;

var

  Fetched: ULONG;

begin

  Fetched:= 0;

  // Windows may pass a pointer to an array; assign the first element via @elt.

  if (celt>0) and (FIndex=0) then

  begin

    PFormatEtc(@elt)^:= FFmt;

    Inc(FIndex);

    Fetched:= 1;

  end;

  if pceltFetched<>nil then

    pceltFetched^:= Fetched;

  if Fetched=celt then

    Result:= S_OK

  else

    Result:= S_FALSE;

end;



function TEnumFormatEtc.Skip(celt: ULONG): HRESULT; stdcall;

begin

  Inc(FIndex, integer(celt));

  if FIndex>1 then

  begin

    FIndex:= 1;

    Result:= S_FALSE;

  end

  else

    Result:= S_OK;

end;



function TEnumFormatEtc.Reset: HRESULT; stdcall;

begin

  FIndex:= 0;

  Result:= S_OK;

end;



function TEnumFormatEtc.Clone(out enumFormatEtc: IEnumFORMATETC): HRESULT; stdcall;

begin

  enumFormatEtc:= TEnumFormatEtc.Create(FFmt, FIndex);

  Result:= S_OK;

end;



{ TFileDataObject }



constructor TFileDataObject.Create(const AFiles: array of UnicodeString);

var

  i: integer;

begin

  inherited Create;

  SetLength(FFiles, Length(AFiles));

  for i:= 0 to High(AFiles) do

    FFiles[i]:= AFiles[i];

  AppDragDebugLog(Format('IDataObject.Create files=%d', [Length(FFiles)]));

end;



function TFileDataObject.MakeFormatEtc: FORMATETC;

begin

  FillChar(Result, SizeOf(Result), 0);

  Result.cfFormat:= cCF_HDROP;

  Result.ptd:= nil;

  Result.dwAspect:= cDVASPECT_CONTENT;

  Result.lindex:= -1;

  Result.tymed:= TYMED_HGLOBAL;

end;



function TFileDataObject.CreateDropHandle: HGLOBAL;

var

  Drop: PDROPFILES;

  Dest: PWideChar;

  DataSize: SizeUInt;

  i: integer;

begin

  AppDragDebugLog('CreateDropHandle enter');

  DataSize:= SizeOf(DROPFILES)+SizeOf(WideChar);

  for i:= 0 to High(FFiles) do

    Inc(DataSize, (Length(FFiles[i])+1)*SizeOf(WideChar));



  Result:= GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, DataSize);

  if Result=0 then

    RaiseLastOSError;

  Drop:= GlobalLock(Result);

  if Drop=nil then

  begin

    GlobalFree(Result);

    RaiseLastOSError;

  end;

  try

    Drop^.pFiles:= SizeOf(DROPFILES);

    Drop^.fWide:= true;

    Dest:= PWideChar(PByte(Drop)+SizeOf(DROPFILES));

    for i:= 0 to High(FFiles) do

    begin

      Move(PWideChar(FFiles[i])^, Dest^,

        Length(FFiles[i])*SizeOf(WideChar));

      Inc(Dest, Length(FFiles[i])+1);

    end;

  finally

    GlobalUnlock(Result);

  end;

  AppDragDebugLog(Format('CreateDropHandle ok size=%u', [DataSize]));

end;



function TFileDataObject.GetData(const formatetcIn: FORMATETC;

  out medium: STGMEDIUM): HRESULT; stdcall;

begin

  AppDragDebugLog(Format('IDataObject.GetData cf=%d tymed=%d aspect=%d',

    [formatetcIn.cfFormat, formatetcIn.tymed, formatetcIn.dwAspect]));

  FillChar(medium, SizeOf(medium), 0);

  Result:= QueryGetData(formatetcIn);

  if Result<>S_OK then

  begin

    AppDragDebugLog(Format('IDataObject.GetData reject hr=0x%.8x', [DWORD(Result)]));

    exit;

  end;

  medium.tymed:= TYMED_HGLOBAL;

  medium.hGlobal:= CreateDropHandle;

  medium.pUnkForRelease:= nil;

  Result:= S_OK;

  AppDragDebugLog('IDataObject.GetData ok');

end;



function TFileDataObject.GetDataHere(const pformatetc: FORMATETC;

  out medium: STGMEDIUM): HRESULT; stdcall;

begin

  AppDragDebugLog('IDataObject.GetDataHere');

  Result:= E_NOTIMPL;

end;



function TFileDataObject.QueryGetData(

  const pformatetc: FORMATETC): HRESULT; stdcall;

begin

  if (pformatetc.cfFormat=cCF_HDROP) and

    ((pformatetc.tymed and TYMED_HGLOBAL)<>0) and

    (pformatetc.dwAspect=cDVASPECT_CONTENT) then

    Result:= S_OK

  else

    Result:= cDV_E_FORMATETC;

end;



function TFileDataObject.GetCanonicalFormatEtc(

  const pformatetcIn: FORMATETC;

  out pformatetcOut: FORMATETC): HRESULT; stdcall;

begin

  pformatetcOut:= pformatetcIn;

  pformatetcOut.ptd:= nil;

  Result:= cDATA_S_SAMEFORMATETC;

end;



function TFileDataObject.SetData(const pformatetc: FORMATETC;

  var medium: STGMEDIUM; FRelease: BOOL): HRESULT; stdcall;

begin

  Result:= E_NOTIMPL;

end;



function TFileDataObject.EnumFormatEtc(dwDirection: DWORD;

  out enumformatetcpara: IEnumFORMATETC): HRESULT; stdcall;

begin

  enumformatetcpara:= nil;

  AppDragDebugLog(Format('IDataObject.EnumFormatEtc dir=%d', [dwDirection]));

  if dwDirection<>DATADIR_GET then

  begin

    Result:= E_NOTIMPL;

    exit;

  end;

  // Custom enumerator — avoid broken FPC SHCreateStdEnumFmtEtc open-array ABI.

  enumformatetcpara:= TEnumFormatEtc.Create(MakeFormatEtc);

  Result:= S_OK;

  AppDragDebugLog('IDataObject.EnumFormatEtc ok (custom enumerator)');

end;



function TFileDataObject.DAdvise(const formatetc: FORMATETC; advf: DWORD;

  const AdvSink: IAdviseSink; out dwConnection: DWORD): HRESULT; stdcall;

begin

  dwConnection:= 0;

  Result:= cOLE_E_ADVISENOTSUPPORTED;

end;



function TFileDataObject.DUnadvise(dwconnection: DWORD): HRESULT; stdcall;

begin

  Result:= cOLE_E_ADVISENOTSUPPORTED;

end;



function TFileDataObject.EnumDAdvise(

  out enumAdvise: IEnumStatData): HRESULT; stdcall;

begin

  enumAdvise:= nil;

  Result:= cOLE_E_ADVISENOTSUPPORTED;

end;



{ TFileDropSource }



function TFileDropSource.QueryContinueDrag(fEscapePressed: BOOL;

  grfKeyState: DWORD): HRESULT; stdcall;

var

  SRes: string;

begin

  if fEscapePressed then

  begin

    FCanceledByEscape:= true;

    Result:= cDRAGDROP_S_CANCEL;

    SRes:= 'CANCEL';

  end

  else

  if (grfKeyState and MK_LBUTTON)=0 then

  begin

    Result:= cDRAGDROP_S_DROP;

    SRes:= 'DROP';

  end

  else

  begin

    Result:= S_OK;

    SRes:= 'S_OK';

  end;

  AppDragDebugLogQcd(fEscapePressed, grfKeyState, SRes);

end;



function TFileDropSource.GiveFeedback(dwEffect: DWORD): HRESULT; stdcall;

begin

  Inc(FGiveFeedbackCount);

  if (FGiveFeedbackCount<=3) or ((FGiveFeedbackCount mod 30)=0) then

    AppDragDebugLog(Format('GiveFeedback #%d effect=0x%x',

      [FGiveFeedbackCount, dwEffect]));

  Result:= cDRAGDROP_S_USEDEFAULTCURSORS;

end;



function ParseFileNames(const AFileNames: string): TUnicodeFileArray;

var

  List: TStringList;

  i: integer;

begin

  SetLength(Result, 0);

  if AFileNames='' then

    raise EArgumentException.Create('File drag list is empty');

  List:= TStringList.Create;

  try

    List.StrictDelimiter:= true;

    List.Delimiter:= cFileSeparator;

    List.DelimitedText:= AFileNames;

    SetLength(Result, List.Count);

    for i:= 0 to List.Count-1 do

    begin

      if List[i]='' then

        raise EArgumentException.Create(

          'File drag list contains an empty path');

      if not FileExistsUTF8(List[i]) and not DirectoryExistsUTF8(List[i]) then

        raise EFileNotFoundException.CreateFmt(

          'File drag path does not exist: %s', [List[i]]);

      Result[i]:= UTF8Decode(List[i]);

    end;

  finally

    List.Free;

  end;

end;



function AppDragFiles(const AFileNames: string;

  out ACanceledByEscape: boolean): boolean;

var

  Files: TUnicodeFileArray;

  DataObject: IDataObject;

  DropSource: IDropSource;

  SourceObj: TFileDropSource;

  Effect: DWORD;

  Res, OleInitResult: HRESULT;

  CapBefore, CapAfter: HWND;

begin

  ACanceledByEscape:= false;

  Result:= false;

  Res:= E_FAIL;

  AppDragDebugLog('AppDragFiles enter files='+StringReplace(AFileNames, #1, '|', [rfReplaceAll]));

  Files:= ParseFileNames(AFileNames);

  AppDragDebugLog(Format('ParseFileNames ok count=%d', [Length(Files)]));

  DataObject:= TFileDataObject.Create(Files);

  SourceObj:= TFileDropSource.Create;

  DropSource:= SourceObj;

  Effect:= DROPEFFECT_NONE;



  OleInitResult:= OleInitialize(nil);

  AppDragDebugLog(Format('OleInitialize hr=0x%.8x', [DWORD(OleInitResult)]));

  if Failed(OleInitResult) then

    raise EOSError.CreateFmt('OleInitialize failed: 0x%.8x',

      [DWORD(OleInitResult)]);

  try

    CapBefore:= GetCapture;

    AppDragDebugLog(Format('before clear capture hwnd=0x%x Mouse.Capture=%u DragManager.IsDragging=%d',

      [PtrUInt(CapBefore), Mouse.Capture, Ord(DragManager.IsDragging)]));

    if Mouse.Capture<>0 then

      Mouse.Capture:= 0

    else

      ReleaseCapture;

    CapAfter:= GetCapture;

    AppDragDebugLog(Format('after clear capture hwnd=0x%x Mouse.Capture=%u',

      [PtrUInt(CapAfter), Mouse.Capture]));



    AppDragDebugLog('DoDragDrop ENTER');

    try

      Res:= DoDragDrop(DataObject, DropSource, DROPEFFECT_COPY, @Effect);

      AppDragDebugLog(Format('DoDragDrop LEAVE hr=0x%.8x effect=0x%x',

        [DWORD(Res), Effect]));

    except

      on E: Exception do

      begin

        AppDragDebugLog('DoDragDrop EXCEPTION: '+E.ClassName+': '+E.Message);

        // Recover mouse capture left in a bad state by a failed OLE drag.

        if Mouse.Capture<>0 then

          Mouse.Capture:= 0;

        ReleaseCapture;

        raise;

      end;

    end;

  finally

    OleUninitialize;

    AppDragDebugLog('OleUninitialize done');

  end;



  ACanceledByEscape:= SourceObj.CanceledByEscape;

  Result:= (Res=cDRAGDROP_S_DROP) and

    ((Effect and DROPEFFECT_COPY)<>0);

  AppDragDebugLog(Format('AppDragFiles leave accepted=%d canceledEsc=%d',

    [Ord(Result), Ord(ACanceledByEscape)]));

end;



end.


