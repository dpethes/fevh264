unit CliParams;
{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TArgumentType = (atNone, atInt, atString);

  { TCliOption }
  TCliOption = class
    private
      fshortName: char;
      flongName: string;
      ftype: TArgumentType;
      fdescription: string;
      fvalue: string;
    public
      property ShortName: char read fshortName;
      property LongName: string read flongName;
      property ArgumentType: TArgumentType read ftype;
      property Description: string read fdescription;
      property Value: string read fvalue write fvalue;
      constructor Create(const shortName_: char; const argtype: TArgumentType; const longName_, desc: string);
  end;
  TOptionList = array of TCliOption;

  { TCliOptionHandler }
  TCliOptionHandler = class
    private
      _cmdline: TStringArray;
      definitions: TOptionList;
      usedOptions: TOptionList;
      lastOption: TCliOption;   //cache last option checked by IsSet()
      unparsed: array of string;
      _valid: boolean;
      _errorDesc: string;
      procedure Parse;
    public
      constructor Create;
      destructor Destroy; override;
      procedure AddOption(const shortName: char; const arg: TArgumentType; const longName, desc: string);
      procedure ParseFromCmdLine;
      procedure ParseFromString(line: string);
      function ValidParams: boolean;
      function GetError: string;
      function IsSet(const name: string): boolean;
      function GetOptionValue(const longOptName: string): string;
      function GetShortOptionValue(const shortName: char): string;
      function UnparsedCount: integer;
      function UnparsedValue(const index: word): string;
      function Descriptions: String;
      procedure PrintSetOpts;
    public
      property OptionValue[shortName: char]: string read GetShortOptionValue; default;
  end;

implementation

function ArgTypeToString(const arg: TArgumentType): string;
begin
  result := '';
  case arg of
      atString: result := '<string>';
      atInt:    result := '<int>';
  end;
end;

{ TCliParameter }

constructor TCliOption.Create(const shortName_: char; const argtype: TArgumentType; const longName_, desc: string);
begin
  fshortName := shortName_;
  flongName := longName_;
  ftype := argtype;
  fdescription := desc;
  value := '';
end;

{ TCliOptionHandler }

constructor TCliOptionHandler.Create;
begin
  definitions := TOptionList.Create;
  usedOptions := TOptionList.Create;
  lastOption := nil;
  _valid := false
end;

destructor TCliOptionHandler.Destroy;
var
  d: TCliOption;
begin
  _cmdline := nil;
  for d in definitions do
      d.Free;
  definitions := nil;
  usedOptions := nil;
  _cmdline := nil;
end;

procedure TCliOptionHandler.AddOption(const shortName: char; const arg: TArgumentType; const longName, desc: string);
var
  option: TCliOption;
begin
  option := TCliOption.Create(shortName, arg, longName, desc);
  Insert(option, definitions, 0);
end;

procedure TCliOptionHandler.Parse;
var
  i: integer;
  def: TCliOption;

  function CheckValidArg: boolean;
  begin
    result := true;
    if def.ArgumentType <> atNone then begin
        if i < Length(_cmdline) - 1 then begin
            def.Value := _cmdline[i + 1];
            i += 1;
        end
        else begin
            result := false;
            _valid := false;
            _errorDesc := 'Missing parameter for option: ' + def.LongName;
        end;
    end;
  end;

var
  option: string;
  short_option: char;
  parsed, is_short_opt, match: boolean;

begin
  _valid := true;
  _errorDesc := '';
  i := 0;
  while i < Length(_cmdline) do begin
      option := _cmdline[i];
      parsed := false;
      if (option[1] = '-') and (length(option) >= 2) then begin
          is_short_opt := length(option) = 2;
          if is_short_opt then
              short_option := option[2]
          else
              option := Copy(option, 3, Length(option));

          //find matching option
          for def in definitions do begin
              match := (is_short_opt and (short_option = def.ShortName)) or (option = def.LongName);
              if match then begin
                  if CheckValidArg then begin
                      Insert(def, usedOptions, 0);
                      parsed := true;
                  end;
                  break;
              end;
          end;
          if not parsed then begin
              _valid := false;
              if _errorDesc = '' then
                  _errorDesc := 'unknown option: ' + option;
          end;
          if not _valid then
              exit;
      end else begin
          Insert(option, unparsed, High(unparsed)+1);
      end;
      i += 1;
  end;
end;

procedure TCliOptionHandler.ParseFromCmdLine;
var
  i: integer;
begin
  if Paramcount = 0 then begin
      _valid := true;
  end else begin
      for i := Paramcount downto 1 do
          Insert(ParamStr(i), _cmdline, 0);
      Parse;
  end;
end;

procedure TCliOptionHandler.ParseFromString(line: string);
begin
  _cmdline := line.Split(' ');
  Parse;
end;

function TCliOptionHandler.ValidParams: boolean;
begin
  result := _valid;
end;

function TCliOptionHandler.GetError: string;
begin
  result := _errorDesc;
end;

function TCliOptionHandler.IsSet(const name: string): boolean;
var
  option: TCliOption;
  match, is_short_opt: boolean;
begin
  result := false;
  is_short_opt := Length(name) = 1;
  for option in usedOptions do begin
      match := (option.LongName = name) or (is_short_opt and (option.ShortName = name[1]));
      if match then begin
          result := true;
          lastOption := option;
          exit;
      end;
  end;
end;

function TCliOptionHandler.GetOptionValue(const longOptName: string): string;
begin
  result := '';
  if (lastOption <> nil) and (longOptName = lastOption.LongName) then
      result := lastOption.Value
  else begin
      if not IsSet(longOptName) then
          _errorDesc := 'no value for option'
      else
          result := lastOption.Value;
  end;
end;

function TCliOptionHandler.GetShortOptionValue(const shortName: char): string;
begin
  result := '';
  if (lastOption <> nil) and (shortName = lastOption.ShortName) then
      result := lastOption.Value
  else begin
      if not IsSet(shortName) then
          _errorDesc := 'no value for option'
      else
          result := lastOption.Value;
  end;
end;

function TCliOptionHandler.UnparsedCount: integer;
begin
  result := Length(unparsed);
end;

function TCliOptionHandler.UnparsedValue(const index: word): string;
begin
  if index >= Length(unparsed) then begin
      _errorDesc := 'no unparsed option with index: ' + IntToStr(index);
      result := '';
  end;
  result := unparsed[index];
end;

function TCliOptionHandler.Descriptions: String;
var
  option: TCliOption;
  left: string;
begin
  result := '';
  for option in definitions do begin
      left := format('  -%s, --%s %s', [option.ShortName, option.LongName, ArgTypeToString(option.ArgumentType)]);
      result += format('%-28s', [left]) + option.Description + LineEnding;
  end;
end;

procedure TCliOptionHandler.PrintSetOpts;
var
  option: TCliOption;
  s: String;
begin
  for option in usedOptions do
      writeln(option.LongName + ': ' + option.Value);
  for s in unparsed do
      writeln(s);
end;

end.

