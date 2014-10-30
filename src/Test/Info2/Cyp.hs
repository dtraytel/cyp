module Test.Info2.Cyp (
  proof
, proofFile
, Err
) where

import Data.Char
import Control.Applicative ((<$>))
import Control.Monad
import Data.Foldable (traverse_)
import Data.List
import Data.Maybe
import Data.Traversable (traverse)
import Text.Parsec as Parsec
import Language.Haskell.Exts.Parser 
import Language.Haskell.Exts.Fixity
import qualified Language.Haskell.Exts.Syntax as Exts
import Language.Haskell.Exts.Syntax (Literal (..), QName(..), SpecialCon (..), Name (..), ModuleName (..), Exp (..), QOp (..), Assoc(..))
import Debug.Trace
import Text.Show.Pretty (ppShow)
import Text.PrettyPrint (comma, empty, fsep, nest, punctuate, quotes, text, vcat, (<>), (<+>), ($+$), Doc)

data ParseDeclTree
    = DataDecl String
    | SymDecl String
    | Axiom String
    | FunDef String
    | Goal String
    deriving Show

data ParseLemma = ParseLemma AProp ParseProof deriving Show -- Proposition, Proof

data ParseProof
    = ParseInduction String String [(String, [ATerm])] -- DataTyp, Over, Cases
    | ParseEquation [ATerm]
    deriving Show

type ParseEquations = [String]

data Env = Env
    { datatypes :: [DataType]
    , axioms :: [Prop]
    , constants :: [String]
    , goals :: [AProp]
    }
    deriving Show

data DataType = DataType String [(String, [TConsArg])] -- name cases
    deriving (Show)

data Prop = Prop Term Term
    deriving (Eq, Show) -- lhs, rhs

data Proof
    = Induction DataType String [(String, [Term])] -- typ ,ind var, ...
    | Equation [Term]
    deriving (Show)

data Lemma = Lemma Prop Proof -- Proposition (_ = _), Proof
    deriving (Show)


data Term
    = Application Term Term
    | Const String
    | Free String -- Free variable
    | Schematic String -- Schematic variable
    | Literal Literal
    deriving (Show, Eq)

-- Term, annotated with original string representation
data ATerm = ATerm String Term deriving Show

data AProp = AProp String Prop deriving Show

data TConsArg = TNRec | TRec deriving (Show,Eq)

type Err a = Either Doc a


{- Debug tools ------------------------------------------------------}

tracePretty :: Show a => a -> b -> b
tracePretty = trace . ppShow

tracePrettyA :: Show a => a -> a
tracePrettyA x = tracePretty x x

tracePrettyF :: Show b => (a -> b) -> a -> a
tracePrettyF f x = tracePretty (f x) x

{- Error handling combinators ---------------------------------------}

err :: Doc -> Err a
err = Left

errStr :: String -> Err a
errStr = Left . text

errCtxt :: Doc -> Err a -> Err a
errCtxt d1 (Left d2) = Left $ indent d1 d2
errCtxt _ x = x

errCtxtStr :: String -> Err a -> Err a
errCtxtStr = errCtxt . text

indent :: Doc -> Doc -> Doc
indent d1 d2 = d1 $+$ nest 4 d2

eitherToErr :: Show a => Either a b -> Err b
eitherToErr (Left x) = err $ foldr ($+$) empty (map text $lines $ show x)
eitherToErr (Right x) = Right x


{- Term operations ---------------------------------------------------}

stripComb :: Term -> (Term, [Term])
stripComb term = work (term, [])
  where work (Application f a, xs) = work (f, a : xs)
        work x = x

listComb :: Term -> [Term] -> Term
listComb = foldl Application

mApp :: Monad m => m Term -> m Term -> m Term
mApp = liftM2 Application

infixl 1 `mApp`
infixl 1 `Application`

match :: Term -> Term -> [(String, Term)] -> Maybe [(String, Term)]
match (Application f a) (Application f' a') s = match f f' s >>= match a a'
match t (Schematic v) s = case lookup v s of
    Nothing -> Just $ (v,t) : s
    Just t' -> if t == t' then Just s else Nothing
match term pat s
    | term == pat = Just s
    | otherwise = Nothing

subst :: Term -> [(String, Term)] -> Term
subst (Application f a) s = Application (subst f s) (subst a s)
subst (Schematic v) s = case lookup v s of
      Nothing -> Schematic v
      Just t -> t
subst t _ = t

collectFrees :: Term -> [String]-> [String]
collectFrees (Application f a) xs = collectFrees f $ collectFrees a xs
collectFrees (Const _) xs = xs
collectFrees (Free v) xs = v : xs
collectFrees (Literal _) xs = xs
collectFrees (Schematic _) xs = xs

isFree :: Term -> Bool
isFree (Free _) = True
isFree _ = False

symPropEq :: String
symPropEq = ".=."

symUMinus :: String
symUMinus = "-"

defConsts :: [String]
defConsts = [symPropEq]


{- ATerm and AProp operations-----------------------------------------}

atermTerm :: ATerm -> Term
atermTerm (ATerm _ term) = term

atermDoc :: ATerm -> Doc
atermDoc (ATerm s _) = text s

apropProp :: AProp -> Prop
apropProp (AProp _ p) = p

apropDoc :: AProp -> Doc
apropDoc (AProp s _) = text s

-- Use with care -- should not invalidate representation
atermMap :: (Term -> Term) -> ATerm -> ATerm
atermMap f (ATerm s term) = ATerm s (f term)


{- Prop operations --------------------------------------------------}

matchProp :: Prop -> Prop -> [(String, Term)] -> Maybe [(String, Term)]
matchProp (Prop l r) (Prop l' r') = match l l' >=> match r r'

substProp :: Prop -> [(String, Term)] -> Prop
substProp (Prop l r) s = Prop (subst l s) (subst r s)



{- Main -------------------------------------------------------------}

proofFile :: FilePath -> FilePath -> IO (Err ())
proofFile masterFile studentFile = do
    mContent <- readFile masterFile
    sContent <- readFile studentFile
    return $ proof (masterFile, mContent) (studentFile, sContent)

proof :: (String, String) -> (String, String) -> Err ()
proof (mName, mContent) (sName, sContent) = do
    env <- processMasterFile mName mContent
    lemmaStmts <- processProofFile env sName sContent
    results <- checkProofs env lemmaStmts
    case filter (not . contained results) $ goals env of
        [] -> return ()
        xs -> err $ indent (text "The following goals are still open:") $
            vcat $ map apropDoc xs
  where
    contained props (AProp _ goal) = any (\x -> isJust $ matchProp goal x []) props

processMasterFile :: FilePath -> String -> Err Env
processMasterFile path content = errCtxtStr "Parsing background theory" $ do
    mResult <- eitherToErr $ Parsec.parse masterParser path content
    dts <- readDataType mResult
    syms <- readSym mResult
    (fundefs, consts) <- readFunc syms mResult
    axs <- readAxiom consts mResult
    gls <- readGoal consts mResult
    return $ Env { datatypes = dts, axioms = fundefs ++ axs,
        constants = nub $ defConsts ++ consts, goals = gls }

processProofFile :: Env -> FilePath -> String -> Err [ParseLemma]
processProofFile env path  content= errCtxtStr "Parsing proof" $
    eitherToErr $ Parsec.runParser studentParser env path content

checkProofs :: Env -> [ParseLemma] -> Err [Prop]
checkProofs env []  = Right $ axioms env
checkProofs env (l@(ParseLemma aprop _) : ls) = do
    errCtxt (text "Lemma:" <+> apropDoc aprop) $
        checkProof env l
    checkProofs (env { axioms = apropProp aprop : axioms env}) ls

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right

checkProof :: Env -> ParseLemma -> Err ()
checkProof env (ParseLemma aprop (ParseEquation eqns)) = errCtxtStr "Equational proof" $
    validEquationProof (axioms env) eqns (apropProp aprop)
checkProof env (ParseLemma aprop (ParseInduction dtRaw overRaw casesRaw)) = errCtxt ctxtMsg $ do
    dt <- validateDatatype dtRaw
    over <- validateOver overRaw
    validateCases dt over casesRaw
  where
    ctxtMsg = text "Induction over variable"
        <+> quotes (text overRaw) <+> text "of type" <+> quotes (text dtRaw)
    lookupCons name (DataType _ conss) = case find (\c -> fst c == name) conss of
        Nothing -> err (text "Invalid case" <+> quotes (text name) <> comma
            <+> text "expected one of"
            <+> (fsep . punctuate comma . map (quotes . text . fst) $ conss))
        Just x -> return x

    validateCase :: DataType -> String -> (String, [ATerm]) -> Err ()
    validateCase dt over (name, steps) = errCtxt (text "Case" <+> quotes (text name)) $ do
        cons <- lookupCons name dt
        indHyps <- computeIndHyps (apropProp aprop) steps over cons
        validEquations (indHyps ++ axioms env) steps

    validateDatatype name = case find (\dt -> getDtName dt == name) (datatypes env) of
        Nothing -> err $ fsep $
            [ text "Invalid datatype" <+> quotes (text name) <> text "."
            , text "Expected one of:" ]
            ++ punctuate comma (map (quotes . text . getDtName) $ datatypes env)
        Just dt -> Right dt

    validateOver s = do
        term <- iparseTerm (defaultToFree $ constants env) s
        case term of
            Free v -> return v
            _ -> err $ text "Term" <+> quotes (text s)
                <+> text "is not a valid induction variable"

    validateCases dt over cases = do
        case missingCase of
            Nothing -> return ()
            Just (name, _) -> errStr $ "Missing case '" ++ name ++ "'"
        traverse_ (validateCase dt over) cases
      where
        caseNames = map fst cases
        missingCase = find (\(name, _) -> name `notElem` caseNames) (getDtConss dt)

    getDtConss (DataType _ conss) = conss
    getDtName (DataType n _) = n

validEquations :: [Prop] -> [ATerm] -> Err ()
validEquations _ [] = errStr "Empty equation sequence"
validEquations _ [_] = Right ()
validEquations rules (t1:t2:ts)
    | rewritesTo rules (atermTerm t1) (atermTerm t2) = validEquations rules (t2:ts)
    | otherwise = errCtxtStr "Invalid proof step" $
        err $ atermDoc t1 $+$ text symPropEq $+$ atermDoc t2

validEquationProof :: [Prop] -> [ATerm] -> Prop -> Err ()
validEquationProof rules eqns aim = do
    validEquations rules eqns
    let (l, r) = (head $ eqns, last $ eqns)
    let proved = Prop (atermTerm l) (atermTerm $ r)
    unless (isFixedProp proved aim) $
        err $ text "Proved proposition does not match goal:" `indent`
            (atermDoc l <+> text symPropEq <+> atermDoc r)

isFixedProp :: Prop -> Prop -> Bool
isFixedProp fixedProp schemProp = isJust $ do
    inst <- map snd <$> matchProp fixedProp schemProp []
    let (Prop schemL schemR) = schemProp
    let schemFrees = collectFrees schemL $ collectFrees schemR $ []
    guard $ all isFree inst && nub inst == inst && null schemFrees

rewriteTop :: Term -> Prop -> Maybe Term
rewriteTop t (Prop lhs rhs) = fmap (subst rhs) $ match t lhs []

rewrite :: Term -> Prop -> [Term]
rewrite t@(Application f a) prop =
    maybeToList (rewriteTop t prop)
    ++ map (\x -> Application x a) (rewrite f prop)
    ++ map (Application f) (rewrite a prop)
rewrite t prop = maybeToList $ rewriteTop t prop

rewritesTo :: [Prop] -> Term -> Term -> Bool
rewritesTo rules l r = l == r || rewrites l r || rewrites r l
  where rewrites from to = any (\x -> isJust $ match to x []) $ concatMap (rewrite from) rules 

computeIndHyps :: Prop -> [ATerm] -> String -> (String, [TConsArg]) -> Err [Prop]
computeIndHyps prop step over con = do
    inst <- case matchInductVar prop $ Prop (atermTerm $ head step) (atermTerm $ last step) of
            Nothing -> err $ text "Proved proposition does not match subgoal:" `indent`
                (text "Proposition: " <+> atermDoc (head step) <+> text symPropEq <+> atermDoc (last step))

            Just x -> Right x
    (recVars, nonrecVars) <- matchInstWithCon con (stripComb inst)
    let instVars = recVars ++ nonrecVars
    when (nub instVars /= instVars) $
        errStr "The induction variables must be distinct!"
    return $ map (\v -> substProp prop [(over, Free v)]) recVars
  where
    matchInductVar :: Prop -> Prop -> Maybe Term
    matchInductVar pat term = do
        s <- matchProp term pat []
        guard $ instOnly over s
        lookup over s
      where instOnly x = all (\(var,inst) -> var == x || Free var == inst)

    matchInstWithCon :: (String, [TConsArg]) -> (Term, [Term]) -> Err ([String], [String])
    matchInstWithCon (conName, conArgs) (f, args)
        | Const conName /= f = errStr $ "Equations and case do not match: "
            ++ show (Const conName) ++ " vs. " ++ show f
        | otherwise = do
            let (rec, nonRec) = partition (\(x,_) -> x == TRec) (conArgs `zip` args)
            liftM2 (,) (traverse (safeFromFree . snd) rec) (traverse (safeFromFree . snd) nonRec)
        where
            safeFromFree (Free v) = return v
            safeFromFree term = errStr $ "Term '" ++ show term ++ "' used in induction is not a variable."


readDataType :: [ParseDeclTree] -> Err [DataType]
readDataType = sequence . mapMaybe parseDataType
  where
    parseDataType (DataDecl s) = Just $ errCtxt (text "Parsing the datatype declaration" <+> quotes (text s)) $ do
        (tycon : dacons) <- traverse parseCons $ splitStringAt "=|" s []
        tyname <- constName $ fst $ stripComb tycon
        dacons' <- traverse (parseDacon tycon) dacons
        return $ DataType tyname dacons'
    parseDataType _ = Nothing

    parseCons :: String -> Err Term
    parseCons = iparseTerm (Right . Free)

    constName (Const c) = return c
    constName term = errStr $ "Term '" ++ show term ++ "' is not a constant."

    parseDacon tycon term = do
        let (con, args) = stripComb term
        name <- constName con
        args' <- traverse (parseDaconArg tycon) args
        return (name, args')

    parseDaconArg tycon term | term == tycon = return TRec
    parseDaconArg _ (Application _ _) = errStr $ "Nested constructors (apart from direct recursion) are not allowed."
    parseDaconArg _ (Literal _) = errStr $ "Literals not allowed in datatype declarations"
    parseDaconArg _ _ = return TNRec

readAxiom :: [String] -> [ParseDeclTree] -> Err [Prop]
readAxiom consts = sequence . mapMaybe parseAxiom
  where
    parseAxiom (Axiom s) = Just $ iparseProp (defaultToSchematic consts) s
    parseAxiom _ = Nothing

readGoal :: [String] -> [ParseDeclTree] -> Err [AProp]
readGoal consts = sequence . mapMaybe parseGoal
  where
    parseGoal (Goal s) = Just $ AProp s <$> iparseProp (defaultToFree consts) s
    parseGoal _ = Nothing

readSym :: [ParseDeclTree] -> Err [String]
readSym = sequence . mapMaybe parseSym
  where
    parseSym (SymDecl s) = Just $ do
        term <- iparseTerm (Right . Const) s
        case term of
            Const v -> Right v
            _ -> errStr $ "Expression '" ++ s ++ "' is not a symbol"
    parseSym _ = Nothing


readFunc :: [String] -> [ParseDeclTree] -> Err ([Prop], [String])
readFunc syms pds = do
    rawDecls <- sequence . mapMaybe parseFunc $ pds
    let syms' = syms ++ map (\(sym, _, _) -> sym) rawDecls
    props <- traverse (declToProp syms') rawDecls
    return (props, syms')
  where

    declToProp :: [String] -> (String, [Exts.Pat], Exts.Exp) -> Err Prop
    declToProp consts (funSym, pats, rawRhs) = do
        tPat <- traverse translatePat pats
        rhs <- translateExp tv rawRhs
        return $ Prop (listComb (Const funSym) tPat) rhs
      where
        pvars = concatMap collectPVars pats
        tv s | s `elem` pvars = return $ Schematic s
             | s `elem` consts = return $ Const s
             | otherwise = errStr $ "Unbound variable '" ++ s ++ "' not allowed on rhs"

    collectPVars :: Exts.Pat -> [String]
    collectPVars (Exts.PVar v) = [translateName v]
    collectPVars (Exts.PInfixApp p1 _ p2) = collectPVars p1 ++ collectPVars p2
    collectPVars (Exts.PApp _ ps) = concatMap collectPVars ps
    collectPVars (Exts.PList ps) = concatMap collectPVars ps
    collectPVars (Exts.PParen p) = collectPVars p
    collectPVars _ = []

    parseFunc :: ParseDeclTree -> Maybe (Err (String, [Exts.Pat], Exts.Exp))
    parseFunc (FunDef s) = Just $ errCtxt (text "Parsing function definition" <+> quotes (text s)) $
        case parseDecl s of
            ParseOk (Exts.FunBind [Exts.Match _ name pat _ (Exts.UnGuardedRhs rhs) (Exts.BDecls [])])
                -> Right (translateName name, pat, rhs)
            ParseOk _ -> errStr "Invalid function definition."
            f@(ParseFailed _ _ ) -> errStr $ show f
    parseFunc _ = Nothing

splitStringAt :: Eq a => [a] -> [a] -> [a] -> [[a]]
splitStringAt _ [] h 
	| h == [] = []
	| otherwise = h : []
splitStringAt a (x:xs) h 
	| x `elem` a = h : splitStringAt a xs []
	| otherwise = splitStringAt a xs (h++[x])
												 

{- Pretty printing --------------------------------------------------}

printProp :: Prop -> String
printProp (Prop l r) = printInfo l ++ " = " ++ printInfo r

printInfo :: Term -> String
printInfo (Application termCurry term) = "((" ++ (printInfo termCurry) ++ ") " ++ (printInfo term) ++ ")"
printInfo (Literal a) = translateLiteral a
printInfo (Const a) = a
printInfo (Free a) = "!" ++ a
printInfo (Schematic a) = "?" ++ a


{- Transform Exp to Term ---------------------------------------------}

translateExp :: (String -> Err Term) -> Exp -> Err Term
translateExp f (Var v) = f =<< translateQName v
translateExp _ (Con c) = Const <$> translateQName c
translateExp _ (Lit l) = Right $ Literal l
translateExp f (InfixApp e1 op e2) =
    translateQOp f op `mApp` translateExp f e1 `mApp` translateExp f e2
translateExp f (App e1 e2) = translateExp f e1 `mApp` translateExp f e2
translateExp f (NegApp e) = return (Const symUMinus) `mApp` translateExp f e
translateExp f (LeftSection e op) = translateQOp f op `mApp` translateExp f e
translateExp f (Paren e) = translateExp f e
translateExp f (List l) = foldr (\e es -> Right (Const ":") `mApp` translateExp f e `mApp` es) (Right $ Const "[]") l
translateExp _ e = errStr $ "Unsupported expression syntax used: " ++ show e

translatePat :: Exts.Pat -> Err Term
translatePat (Exts.PVar v) = Right $ Schematic $ translateName v
translatePat (Exts.PLit l) = Right $ Literal l
-- PNeg?
translatePat (Exts.PNPlusK _ _) = errStr "n+k patterns are not supported"
translatePat (Exts.PInfixApp p1 qn p2) =
    (Const <$> translateQName qn) `mApp` translatePat p1 `mApp` translatePat p2
translatePat (Exts.PApp qn ps) = do
    cs <- traverse translatePat ps
    n <- translateQName qn
    return $ listComb (Const n) cs
translatePat (Exts.PTuple _) = errStr "tuple patterns are not supported"
translatePat (Exts.PList ps) = foldr (\p cs -> Right (Const ":") `mApp` translatePat p `mApp` cs) (Right $ Const "[]") ps
translatePat (Exts.PParen p) = translatePat p
translatePat (Exts.PAsPat _ _) = errStr "as patterns are not supported"
translatePat Exts.PWildCard = errStr "wildcard patterns are not supported"
translatePat f = errStr $ "unsupported pattern type: " ++ show f

translateQOp :: (String -> Err Term) -> QOp -> Err Term
translateQOp _ (QConOp op) = Const <$> translateQName op
translateQOp f (QVarOp op) = f =<< translateQName op

translateQName :: QName -> Err String
translateQName (Qual (ModuleName m) (Ident n)) = return $ m ++ "." ++ n
translateQName (Qual (ModuleName m) (Symbol n)) = return $ m ++ "." ++ n
translateQName (UnQual (Ident n)) = return n
translateQName (UnQual (Symbol n)) = return n
translateQName (Special UnitCon) = return "()"
translateQName (Special ListCon) = return "[]"
translateQName (Special FunCon) = return "->"
translateQName (Special Cons) = return ":"
translateQName q = errStr $ "Unsupported QName '" ++ show q ++ "'."

translateLiteral :: Literal -> String
translateLiteral (Char c) = [c]
translateLiteral (String s) = s
translateLiteral (Int c) = show c
translateLiteral (Frac c) = show c
translateLiteral (PrimInt c) = show c
translateLiteral (PrimWord c) = show c
translateLiteral (PrimFloat c) = show c
translateLiteral (PrimDouble c) = show c
translateLiteral (PrimChar c) = [c]
translateLiteral (PrimString c) = c

translateName :: Name -> String
translateName (Ident s) = s
translateName (Symbol s) = s


{- Parser for the expression syntax ---------------------------------}

iparseTermRaw :: ParseMode -> (String -> Err Term) -> String -> Err Term
iparseTermRaw mode f s = errCtxt (text "Parsing term" <+> quotes (text s)) $
    case parseExpWithMode mode s of
        ParseOk p -> translateExp f p
        x@(ParseFailed _ _) -> errStr $ show x

defaultToFree :: [String] -> String -> Err Term
defaultToFree consts x = return $ if x `elem` consts then Const x else Free x

defaultToSchematic :: [String] -> String -> Err Term
defaultToSchematic consts x = return $ if x `elem` consts then Const x else Schematic x

checkHasPropEq :: Term -> Err ()
checkHasPropEq term = when (hasPropEq term) $
    errStr $ "A term may not include the equality symbol '" ++ symPropEq ++ "'."
  where
    hasPropEq (Application f a) = hasPropEq f || hasPropEq a
    hasPropEq (Const c) | c == symPropEq = True
    hasPropEq _ = False

iparseTerm :: (String -> Err Term)-> String -> Err Term
iparseTerm f s = do
    term <- iparseTermRaw baseParseMode f s
    checkHasPropEq term
    return term

iparseProp :: (String -> Err Term) -> String -> Err Prop
iparseProp f s = do
    term <- iparseTermRaw mode f' s
    (lhs, rhs) <- case term of
        Application (Application (Const c) lhs) rhs | c == symPropEq -> Right (lhs, rhs)
        _ -> errStr $ "Term '" ++ s ++ "' is not a proposition"
    checkHasPropEq lhs
    checkHasPropEq rhs
    return $ Prop lhs rhs
  where
    f' x = if x == symPropEq then return $ Const x else f x
    mode = baseParseMode { fixities = Just $ Fixity AssocNone (-1) (UnQual $ Symbol symPropEq) : baseFixities }

{- Parser for the outer syntax --------------------------------------}

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

toParsec :: (a -> String) -> Either a b -> Parsec c u b
toParsec f = either (fail . f) return

eol :: Parsec [Char] u ()
eol = do
    _ <- try (string "\n\r") <|> try (string "\r\n") <|> string "\n" <|> string "\r" -- <|> (eof >> return "")
        <?> "end of line"
    return ()

commentParser :: Parsec [Char] u ()
commentParser =
    do  _ <- string "--"
        _ <- many (noneOf "\r\n")
        eol <|> eof
        return ()
longcommentParser :: Parsec [Char] u ()
longcommentParser =
    do  _ <- string "{-"
        _ <- manyTill anyChar (try (string "-}"))
        return ()

commentParsers :: Parsec [Char] u ()
commentParsers = commentParser <|> longcommentParser <?> "comment"

masterParser :: Parsec [Char] () [ParseDeclTree]
masterParser =
    do result <- many masterParsers
       eof
       return result

masterParsers :: Parsec [Char] () ParseDeclTree
masterParsers =
    do manySpacesOrComment
       result <- (goalParser <|> dataParser <|> axiomParser <|> symParser <|> try funParser)
       return result

keywordToEolParser :: String -> (String -> a) -> Parsec [Char] () a
keywordToEolParser s f =
    do  keyword s
        result <- trim <$> toEol
        return (f result)

axiomParser :: Parsec [Char] () ParseDeclTree
axiomParser = keywordToEolParser "axiom" Axiom

dataParser :: Parsec [Char] () ParseDeclTree
dataParser = keywordToEolParser "data" DataDecl

goalParser :: Parsec [Char] () ParseDeclTree
goalParser = keywordToEolParser "goal" Goal

symParser :: Parsec [Char] () ParseDeclTree
symParser = keywordToEolParser "declare_sym" SymDecl

funParser :: Parsec [Char] () ParseDeclTree
funParser =
    do  c <- noneOf "\r\n"
        cs <- toEol
        return (FunDef $ c:cs)

equationProofParser :: Parsec [Char] Env ParseProof
equationProofParser = do
    keyword "Proof"
    eqns <- equationsParser
    manySpacesOrComment
    keywordQED
    return $ ParseEquation eqns

inductionProofParser :: Parsec [Char] Env ParseProof
inductionProofParser =
    do  keyword "Proof by induction on"
        datatype <- many (noneOf " \t")
        lineSpaces
        over <- toEol
        manySpacesOrComment
        cases <- many1 caseParser
        manySpacesOrComment
        keywordQED
        return (ParseInduction datatype over cases)

propParser :: Parsec [Char] Env AProp
propParser = do
    s <- trim <$> toEol1
    env <- getState
    let aprop = errCtxtStr "Failed to parse expression" $ do
            AProp s <$> iparseProp (defaultToSchematic $ constants env) s
    toParsec show aprop

lemmaParser :: Parsec [Char] Env ParseLemma
lemmaParser =
    do  keyword "Lemma:"
        aprop <- propParser
        manySpacesOrComment
        prf <- inductionProofParser <|> equationProofParser
        manySpacesOrComment
        return $ ParseLemma aprop prf

studentParser ::  Parsec [Char] Env [ParseLemma]
studentParser =
    do  lemmas <- many1 lemmaParser
        eof
        return lemmas

lineSpaces :: Parsec [Char] u ()
lineSpaces = skipMany (oneOf " \t") <?> "horizontal white space"

keyword :: String -> Parsec [Char] u ()
keyword kw = try $ do
    _ <- string kw
    notFollowedBy alphaNum
    lineSpaces

keywordCase :: Parsec [Char] u ()
keywordCase = keyword "Case"

keywordQED :: Parsec [Char] u ()
keywordQED = keyword "QED"

toEol :: Parsec [Char] u String
toEol = manyTill anyChar (eof <|> try eol <|> try commentParser)

toEol1 :: Parsec [Char] u String
toEol1 = do
    cs <- toEol
    case cs of
        [] -> unexpected "missing text before eol or comment"
        _ -> return cs

equationsParser :: Parsec [Char] Env [ATerm]
equationsParser = do
    eq1 <- equations'
    eq2 <- option [] (try equations')
    return $ eq1 ++ reverse eq2
  where
    equations' = do
        spaces
        l <- toEol
        ls <- many1 (try (manySpacesOrComment >> string symPropEq >> lineSpaces >> toEol))
        env <- getState
        let eqs = errCtxtStr "Failed to parse expression:" $
                traverse (\x -> ATerm x <$> iparseTerm (defaultToFree $ constants env) x) (l : ls)
        toParsec show eqs

caseParser :: Parsec [Char] Env (String, [ATerm])
caseParser = do
    keywordCase
    manySpacesOrComment
    cons <- trim <$> toEol
    manySpacesOrComment
    eqns <- equationsParser
    manySpacesOrComment
    return (cons, eqns)

manySpacesOrComment :: Parsec [Char] u ()
manySpacesOrComment = skipMany $ (space >> return ()) <|> commentParsers

-- Parse Mode with Fixities
baseParseMode :: ParseMode
baseParseMode = defaultParseMode { fixities = Just baseFixities }