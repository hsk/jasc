(*
 *  This file is part of JavaLib
 *  Copyright (c)2004-2012 Nicolas Cannasse and Caue Waneck
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)
open JData;;
open JDataPP;;
open IO.BigEndian;;
open ExtString;;
open ExtList;;

(*let debug = debug0*)


exception Error_message of string

let error fmt = Printf.ksprintf (fun s -> raise (Error_message s)) fmt

let get_reference_type i constid =
  begin match i with
    | 1 -> RGetField
    | 2 -> RGetStatic
    | 3 -> RPutField
    | 4 -> RPutStatic
    | 5 -> RInvokeVirtual
    | 6 -> RInvokeStatic
    | 7 -> RInvokeSpecial
    | 8 -> RNewInvokeSpecial
    | 9 -> RInvokeInterface
    | _ -> error "%d: Invalid reference type %d" constid i
  end

let parse_constant max idx ch =
  let cid = IO.read_byte ch in
  let error() = error "%d: Invalid constant %d" idx cid in
  let index() =
    let n = read_ui16 ch in
    if n = 0 || n >= max then error();
    n
  in
  let index2() =
      let n1 = index() in
      let n2 = index() in
      (n1,n2)
  in
  begin match cid with
    | 0  -> KUnusable
    | 1  -> let len = read_ui16 ch in
            (* TODO: correctly decode modified UTF8 *)
            KUtf8String (IO.nread ch len)
    | 3  -> KInt (read_real_i32 ch)
    | 4  -> KFloat (Int32.float_of_bits (read_real_i32 ch))
    | 5  -> KLong (read_i64 ch)
    | 6  -> KDouble (read_double ch)
    | 7  -> KClass (index())
    | 8  -> KString (index())
    | 9  -> KFieldRef (index2())
    | 10 -> KMethodRef (index2())
    | 11 -> KInterfaceMethodRef (index2())
    | 12 -> KNameAndType (index2())
    | 15 -> let reft = get_reference_type (IO.read_byte ch) idx in
    	      KMethodHandle (reft, index())
    | 16 -> KMethodType (index())
    | 18 -> let bootstrapref = read_ui16 ch in (* not index *)
            KInvokeDynamic (bootstrapref, index())
    | n -> error()
  end

let expand_path s =
  match List.rev (String.nsplit s "/") with
  | name :: tl -> (List.rev tl, name)
  | [] -> assert false

let rec parse_type_parameter_part s =
  match s.[0] with
  | '*' -> (TAny, 1)
  | c   ->
    let (wildcard, i) =
      match c with
      | '+' -> (WExtends, 1)
      | '-' -> (WSuper,   1)
      | _   -> (WNone,    0)
    in
    let (jsig, l) = parse_signature_part (String.sub s i (String.length s - 1)) in
    (TType (wildcard, jsig), l + i)

and parse_signature_part s =
  let len = String.length s in
  if len = 0 then raise Exit;
  match s.[0] with
  | 'B' -> (TByte  , 1)
  | 'C' -> (TChar  , 1)
  | 'D' -> (TDouble, 1)
  | 'F' -> (TFloat , 1)
  | 'I' -> (TInt   , 1)
  | 'J' -> (TLong  , 1)
  | 'S' -> (TShort , 1)
  | 'Z' -> (TBool  , 1)
  | 'L' ->
    begin try
      let orig_s = s in
      let rec loop start i acc =
        match s.[i] with
        | '/' -> loop (i + 1) (i + 1) (String.sub s start (i - start) :: acc)
        | ';' | '.' -> (List.rev acc, (String.sub s start (i - start)), [], i)
        | '<' ->
          let name = String.sub s start (i - start) in
          let rec loop_params i acc =
            let s = String.sub s i (len - i) in
            match s.[0] with
            | '>' -> (List.rev acc, i + 1)
            | _ ->
              let (tp, l) = parse_type_parameter_part s in
              loop_params (l + i) (tp :: acc)
          in
          let (params, _end) = loop_params (i + 1) [] in
          (List.rev acc, name, params, _end)
        | _ -> loop start (i+1) acc
      in
      let (pack, name, params, _end) = loop 1 1 [] in
      let rec loop_inner i acc =
        match s.[i] with
        | '.' ->
          let (pack, name, params, _end) = loop (i+1) (i+1) [] in
          if pack <> [] then
            error "Inner types must not define packages. For '%s'." orig_s;
          loop_inner _end ((name,params) :: acc)
        | ';' -> (List.rev acc, i + 1)
        | c ->
          error "End of complex type signature expected after type parameter. Got '%c' for '%s'."
            c orig_s
      in
      let (inners, _end) = loop_inner _end [] in
      match inners with
      | [] -> (TObject((pack,name), params),                _end)
      | _  -> (TObjectInner(pack, (name,params) :: inners), _end)
    with
      Invalid_string -> raise Exit
    end
  | '[' ->
    let p = ref 1 in
    while !p < String.length s && s.[!p] >= '0' && s.[!p] <= '9' do
      incr p
    done;
    let size =
      if !p > 1
      then Some (int_of_string (String.sub s 1 (!p - 1)))
      else None
    in
    let (s, l) = parse_signature_part (String.sub s !p (String.length s - !p)) in
    (TArray (s, size), l + !p)
  | '(' ->
    let p = ref 1 in
    let args = ref [] in
    while !p < String.length s && s.[!p] <> ')' do
      let (a , l) = parse_signature_part (String.sub s !p (String.length s - !p)) in
      args := a :: !args;
      p := !p + l
    done;
    incr p;
    if !p >= String.length s then raise Exit;
    let (ret, l) =
      begin match s.[!p] with
      | 'V' -> (None, 1)
      | _   ->
        let (s, l) = parse_signature_part (String.sub s !p (String.length s - !p)) in
        (Some s, l)
      end
    in
    (TMethod (List.rev !args,ret), !p + l)
  | 'T' ->
    begin try
      let (s1, _) = String.split s ";" in
      let len = String.length s1 in
      (TTypeParameter (String.sub s1 1 (len - 1)), len + 1)
    with
      Invalid_string -> raise Exit
    end
  | _ ->
    raise Exit

let parse_signature s =
  begin try
    let (sign, l) = parse_signature_part s in
    if String.length s <> l then raise Exit;
    sign
  with
    Exit -> error "Invalid signature '%s'" s
  end

let parse_method_signature s =
  begin match parse_signature s with
    | (TMethod m) -> m
    | _ -> error "Unexpected signature '%s'. Expecting method" s
  end

let parse_formal_type_params s =
  match s.[0] with
  | '<' ->
    let rec read_id i =
      match s.[i] with
      | ':' | '>' -> i
      | _         -> read_id (i + 1)
    in
    let len = String.length s in
    let rec parse_params idx acc =
      let idi = read_id (idx + 1) in
      let id = String.sub s (idx + 1) (idi - idx - 1) in
      (* next must be a : *)
      begin match s.[idi] with
        | ':' -> ()
        | _ ->
          error "Invalid formal type signature character: %c ; from %s"
            s.[idi] s
      end;
      let (ext, l) =
        match s.[idi + 1] with
        | ':' | '>' -> (None, idi + 1)
        | _ ->
          let (sgn, l) = parse_signature_part (String.sub s (idi + 1) (len - idi - 1)) in
          (Some sgn, l + idi + 1)
      in
      let rec loop idx acc =
        match s.[idx] with
        | ':' ->
          let (ifacesig, ifacei) = parse_signature_part (String.sub s (idx + 1) (len - idx - 1)) in
          loop (idx + ifacei + 1) (ifacesig :: acc)
        | _ -> (acc, idx)
      in
      let (ifaces, idx) = loop l [] in
      let acc = (id, ext, ifaces) :: acc in
      if s.[idx] = '>' then (List.rev acc, idx + 1) else
      parse_params (idx - 1) acc
    in
    parse_params 0 []
  | _ -> ([], 0)

let parse_throws s =
  let len = String.length s in
  let rec loop idx acc =
    if idx > len then raise Exit;
    if idx = len then (acc, idx) else
    match s.[idx] with
    | '^' ->
      let (tsig, l) = parse_signature_part (String.sub s (idx+1) (len - idx - 1)) in
      loop (idx + l + 1) (tsig :: acc)
    | _ -> (acc, idx)
  in
  loop 0 []

let parse_complete_method_signature s =
  try
    let len = String.length s in
    let (tparams, i) = parse_formal_type_params s in
    let (sign, l) = parse_signature_part (String.sub s i (len - i)) in
    let (throws, l2) = parse_throws (String.sub s (i+l) (len - i - l)) in
    if (i + l + l2) <> len then raise Exit;
    match sign with
    | TMethod msig -> (tparams, msig, throws)
    | _ -> raise Exit
  with
    Exit -> error "Invalid method extended signature '%s'" s


let rec expand_constant consts i =
  let unexpected i =
    error "%d: Unexpected constant type" i
  in
  let expand_path n =
    match Array.get consts n with
    | KUtf8String s -> expand_path s
    | _ -> unexpected n
  in
  let expand_cls n =
    match expand_constant consts n with
    | ConstClass p -> p
    | _ -> unexpected n
  in
  let expand_nametype n =
    match expand_constant consts n with
    | ConstNameAndType (s, jsig) -> (s, jsig)
    | _ -> unexpected n
  in
  let expand_string n =
    match Array.get consts n with
    | KUtf8String s -> s
    | _ -> unexpected n
  in
  let expand ncls nt =
    match (expand_cls ncls, expand_nametype nt) with
    | (path, (n, m)) -> (path, n, m)
  in
  let expand_m ncls nt =
    let expand_nametype_m n =
      match expand_nametype n with
      | (n, TMethod m) -> (n, m)
      | _              -> unexpected n
    in
    begin match (expand_cls ncls, expand_nametype_m nt) with
      | (path, (n, m)) -> (path, n, m)
    end
  in
  begin match Array.get consts i with
    | KClass utf8ref ->
      ConstClass (expand_path utf8ref)
    | KFieldRef (classref, nametyperef) ->
      ConstField (expand classref nametyperef)
    | KMethodRef (classref, nametyperef) ->
      ConstMethod (expand_m classref nametyperef)
    | KInterfaceMethodRef (classref, nametyperef) ->
      ConstInterfaceMethod (expand_m classref nametyperef)
    | KString utf8ref -> ConstString (expand_string utf8ref)
    | KInt i32 -> ConstInt i32
    | KFloat f -> ConstFloat f
    | KLong i64 -> ConstLong i64
    | KDouble d -> ConstDouble d
    | KNameAndType (n, t) ->
      ConstNameAndType(expand_string n, parse_signature (expand_string t))
    | KUtf8String s ->
      ConstUtf8 s (* TODO: expand UTF8 characters *)
    | KMethodHandle (reference_type, dynref) ->
      ConstMethodHandle (reference_type, expand_constant consts dynref)
    | KMethodType utf8ref ->
      ConstMethodType (parse_method_signature (expand_string utf8ref))
    | KInvokeDynamic (bootstrapref, nametyperef) ->
      let (n, t) = expand_nametype nametyperef in
      ConstInvokeDynamic(bootstrapref, n, t)
    | KUnusable ->
      ConstUnusable
  end
let parse_access_flags ch all_flags =
  let fl = read_ui16 ch in
  let flags = ref [] in
  let fbit = ref 0 in
  List.iter begin fun f ->
    if fl land (1 lsl !fbit) <> 0 then begin
      flags := f :: !flags;
      if f = JUnusable then error "Unusable flag: %d" fl
    end;
    incr fbit
  end all_flags;
  (*if fl land (0x4000 - (1 lsl !fbit)) <> 0
    then error "Invalid access flags %d" fl);*)
  !flags

let get_constant c n =
  if n < 1 || n >= Array.length c then error "Invalid constant index %d" n;
  match c.(n) with
  | ConstUnusable -> error "Unusable constant index";
  | x -> x

let get_class consts ch =
  match get_constant consts (read_ui16 ch) with
  | ConstClass n -> n
  | _ -> error "Invalid class index"

let get_string consts ch =
  let i = read_ui16 ch in
  match get_constant consts i with
  | ConstUtf8 s -> s
  | _ -> error "Invalid string index %d" i

let rec parse_element_value consts ch =
  let tag = IO.read_byte ch in
  let c = Char.chr tag in
  match c with
  | 'B' | 'C' | 'D' | 'E' | 'F' | 'I' | 'J' | 'S' | 'Z' | 's' ->
    ValConst (tag, get_constant consts (read_ui16 ch))
  | 'e' ->
    let path = parse_signature (get_string consts ch) in
    let name = get_string consts ch in
    ValEnum (path, name)
  | 'c' ->
    let name = get_string consts ch in
    let jsig =
      if name = "V" then TObject(([], "Void"), []) else
      parse_signature name
    in
    ValClass jsig
  | '@' ->
    ValAnnotation (parse_annotation consts ch)
  | '[' ->
    let num_vals = read_ui16 ch in
    ValArray (List.init (num_vals) (fun _ -> parse_element_value consts ch))
  | tag -> error "Invalid element value: '%c'" tag

and parse_ann_element consts ch =
  let name = get_string consts ch in
  let element_value = parse_element_value consts ch in
  (name, element_value)

and parse_annotation consts ch =
  let anntype = parse_signature (get_string consts ch) in
  let count = read_ui16 ch in
  {
    ann_type = anntype;
    ann_elements = List.init count (fun _ -> parse_ann_element consts ch)
  }

let parse_attribute on_special consts ch =
  let aname = get_string consts ch in
  let error() = error "Malformed attribute %s" aname in
  let alen = read_i32 ch in
  match aname with
  | "Deprecated" ->
    if alen <> 0 then error();
    Some (AttrDeprecated)
  | "RuntimeVisibleAnnotations" ->
    let anncount = read_ui16 ch in
    Some (AttrVisibleAnnotations (List.init anncount (fun _ -> parse_annotation consts ch)))
  | "RuntimeInvisibleAnnotations" ->
    let anncount = read_ui16 ch in
    Some (AttrInvisibleAnnotations (List.init anncount (fun _ -> parse_annotation consts ch)))
  | _ ->
    let do_default () = Some (AttrUnknown (aname, IO.nread ch alen)) in
    match on_special with
    | None -> do_default()
    | Some fn -> fn consts ch aname alen do_default

let parse_attributes ?on_special consts ch count =
  let rec loop i acc =
    if i >= count then List.rev acc else
    match parse_attribute on_special consts ch with
    | None -> loop (i + 1) acc
    | Some attrib -> loop (i + 1) (attrib :: acc)
  in
  loop 0 []

let parse_field kind consts ch =
  let all_flags =
    match kind with
    | JKField ->
      [ JPublic; JPrivate; JProtected; JStatic; JFinal; JUnusable;
        JVolatile; JTransient; JSynthetic; JEnum ]
    | JKMethod ->
      [ JPublic; JPrivate; JProtected; JStatic; JFinal; JSynchronized;
        JBridge; JVarArgs; JNative; JUnusable; JAbstract; JStrict; JSynthetic ]
  in
  let acc = ref (parse_access_flags ch all_flags) in
  debug "acc %a ok@." pp_jaccess !acc;
  let name = get_string consts ch in
  debug "name %s ok@." name;
  let sign = parse_signature (get_string consts ch) in
  debug "sig ok@.";

  let jsig = ref sign in
  let throws = ref [] in
  let types = ref [] in
  let constant = ref None in
  let code = ref None in

  let attrib_count = read_ui16 ch in
  debug "attrib_count %d ok@." attrib_count;
  let attribs = parse_attributes consts ch attrib_count
    ~on_special:begin fun _ _ aname alen do_default ->
    debug "special kind %a aname %S@." pp_jfield_kind kind aname;
    match (kind, aname) with
    | JKField, "ConstantValue" ->
      constant := Some (get_constant consts (read_ui16 ch));
      None
    | JKField, "Synthetic" ->
      if not (List.mem JSynthetic !acc) then acc := !acc @ [JSynthetic];
      None
    | JKField, "Signature" ->
      let s = get_string consts ch in
      jsig := parse_signature s;
      None
    | JKMethod, "Code" -> (* TODO *)
      Some (AttrUnknown (aname, IO.nread ch alen))
    | JKMethod, "Exceptions" ->
      let num = read_ui16 ch in
      debug "exeption num %d@." num;

      throws := List.init num (fun _ -> TObject(get_class consts ch, []));
      None
    | JKMethod, "Signature" ->
      let s = get_string consts ch in
      let (tp, sgn, thr) = parse_complete_method_signature s in
      if thr <> [] then throws := thr;
      types := tp;
      jsig := TMethod(sgn);
      None
    | _ -> do_default()
  end in
  debug "attribs %a ok@." pp_jattributes attribs;

  {
    jf_name = name;
    jf_kind = kind;
    (* signature, as used by the vm *)
    jf_vmsignature = sign;
    (* actual signature, as used in java code *)
    jf_signature = !jsig;
    jf_throws = !throws;
    jf_types = !types;
    jf_flags = !acc;
    jf_attributes = attribs;
    jf_constant = !constant;
    jf_code = !code;
  }

let parse_class ch =
  if read_real_i32 ch <> 0xCAFEBABEl then error "Invalid header";
  let minorv = read_ui16 ch in
  let majorv = read_ui16 ch in
  let constant_count = read_ui16 ch in

  debug "count=%d %x\n" constant_count  constant_count;
  let const_big = ref true in
  let consts1 = Array.init constant_count (fun idx ->
  	if !const_big then begin
  	  const_big := false;
  	  KUnusable
  	end else
    let c = parse_constant constant_count idx ch in
    (match c with KLong _ | KDouble _ -> const_big := true | _ -> ());
    c
  ) in
  let consts = Array.mapi (fun i _ -> expand_constant consts1 i) consts1 in

  debug "parse_access_flags\n";

  let flags = parse_access_flags ch [
    JPublic; JUnusable; JUnusable; JUnusable; JFinal;
    JSuper; JUnusable; JUnusable; JUnusable;
    JInterface; JAbstract; JUnusable; JSynthetic; JAnnotation; JEnum] in
  debug "get_class@.";
  let this = get_class consts ch in
  debug "read_super@.";
  let super_idx = read_ui16 ch in
  debug "super idx=%d@." super_idx;
  let super = match super_idx with
  	| 0 -> TObject((["java";"lang"], "Object"), []);
  	| idx -> match get_constant consts idx with
  	  | ConstClass path -> TObject(path, [])
  	  | _ -> error "Invalid super index"
  in
  debug "super= %a@." pp_jsignature super;
  let len = (read_ui16 ch) in
  debug "interfaces len = %d@.@?" len;
  let interfaces = List.init len (fun _ -> TObject (get_class consts ch, [])) in
  debug "interfaces %a@." pp_jsignatures interfaces;
  let fields = List.init (read_ui16 ch) (fun _ -> parse_field JKField consts ch) in
  debug "fields ok %a @." pp_jfields fields;
  let methods = List.init (read_ui16 ch) (fun _ -> parse_field JKMethod consts ch) in
  debug "methods ok %a @." pp_jfields methods;

  let inner = ref [] in
  let types = ref [] in
  let super = ref super in
  let interfaces = ref interfaces in

  let attribs = read_ui16 ch in
  debug "attribs %d\n" attribs;
  let attribs = parse_attributes ~on_special:(fun _ _ aname alen do_default ->
    match aname with
    | "InnerClasses" ->
      debug "innerclasses\n";
      let count = read_ui16 ch in
      debug "count %d\n" count;
      let classes = List.init count (fun _ ->
        let inner_ci = get_class consts ch in
        debug "inner_ci\n";
        let outeri = read_ui16 ch in
        let outer_ci =
          begin match outeri with
          | 0 -> None
          | _ ->
            begin match get_constant consts outeri with
            | ConstClass n -> Some n
            | _            -> error "Invalid class index"
            end
          end
        in
        debug "outer_ci\n";

        let inner_namei = read_ui16 ch in
        let inner_name =
          begin match inner_namei with
          | 0 -> None
          | _ ->
            begin match get_constant consts inner_namei with
            | ConstUtf8 s -> Some s
            | _ -> error "Invalid string index %d" inner_namei
            end
          end
        in
        debug "inner_name\n";
        let flags = parse_access_flags ch [
          JPublic; JPrivate; JProtected; JStatic; JFinal;
          JUnusable; JUnusable; JUnusable; JUnusable;
          JInterface; JAbstract; JSynthetic; JAnnotation; JEnum] in
        debug "flags\n";
        (inner_ci, outer_ci, inner_name, flags)
      ) in
      inner := classes;
      None
    | "Signature" ->
      let s = get_string consts ch in
      let (formal, idx) = parse_formal_type_params s in
      types := formal;
      let s = String.sub s idx (String.length s - idx) in
      let len = String.length s in
      let (sup, idx) = parse_signature_part s in
      let rec loop idx acc =
        if idx = len then acc else
        let s = String.sub s idx (len - idx) in
        let (iface, i2) = parse_signature_part s in
        loop (idx + i2) (iface :: acc)
      in
      interfaces := loop idx [];
      super := sup;
      None
    | _ -> do_default()
  ) consts ch attribs in
	IO.close_in ch;
  {
    cversion = (majorv, minorv);
    constants = consts;
    cpath = this;
    csuper = !super;
    cflags = flags;
    cinterfaces = !interfaces;
    cfields = fields;
    cmethods = methods;
    cattributes = attribs;
    cinner_types = !inner;
    ctypes = !types;
  }
