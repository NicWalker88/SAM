##' Calculate jacobian of a function
##'
##' @param func function
##' @param x parameter values
##' @param ... passed to func
##' @return jacobian matrix
##' @author Christoffer Moesgaard Albertsen
jacobian <- function(func, x,
                     h = abs(1e-04 * x) + 1e-04 * (abs(x) < sqrt(.Machine$double.eps/7e-07)),
                     ## 0.1 * 10^floor(log10(abs(x))) + 1e-4,
                     ...){
         r <- .Call("jacobian",
                   function(x)func(x,...),
                   x,
                   globalenv(),
                   30L,
                   h,##abs(1e-4 * x) + 1e-4 * (abs(x) < 1e-8),
                   1e-12)
        do.call("cbind",r[-1])
}
##' Calculate gradient of a function
##'
##' @param func function
##' @param x parameter values
##' @param ... passed to func
##' @return gradient vector
##' @author Christoffer Moesgaard Albertsen
grad <- function(func, x,
                 h = abs(1e-04 * x) + 1e-04 * (abs(x) < sqrt(.Machine$double.eps/7e-07)),
                 ##0.1 * 10^floor(log10(abs(x))) + 1e-4,
                 ...){
         r <- .Call("jacobian",
                   function(x)func(x,...),
                   x,
                   globalenv(),
                   30L,
                   h,##abs(1e-4 * x) + 1e-4 * (abs(x) < 1e-8),
                   1e-12)
         v <- do.call("cbind",r[-1])
         if(nrow(v) == 1)
             return(as.vector(v))
         return(diag(v))         
}

svd_solve <- function(x){
    ss <- svd(x)
    ss$v %*% diag(1/ss$d, length(ss$d), length(ss$d)) %*% t(ss$u)
}


##' Estimating Fmsy
##'
##' Work in progress - do not use
##' @param fit a SAM fit
##' @param nYears Number of years to forecast
##' @param nlminb.control list of control variables for nlminb
##' @param rec.years Numeric vector of years to use (to calculate mean and standard deviation) for recruitment. An empty vector will use the recruitment model.
##' @param processNoiseF Should random walk process noise be used for F?
##' @param ... other arguments passed to forecast
##' @author Christoffer Moesgaard Albertsen
##' @seealso forecast
##' @export
forecastMSY <- function(fit,
                    nYears = 100,
                    nlminb.control = list(eval.max = 2000, iter.max = 2000),
                    rec.years = c(),
                    processNoiseF = FALSE,
                    ...){
    UseMethod("forecastMSY")
}


##' @rdname forecastMSY
##' @method forecastMSY sam
##' @export
forecastMSY.sam <- function(fit,
                            nYears = 100,                            
                            nlminb.control = list(eval.max = 2000, iter.max = 2000, trace = 1),
                            rec.years = c(),
                            processNoiseF = FALSE,
                            jacobianHScale = 0.5,
                            nCatchAverageYears = 20,
                            ...){

    argsIn <- forecast(fit,
                       findMSY = rep(1,nYears),
                       rec.years = rec.years,
                       processNoiseF = processNoiseF,
                       nCatchAverageYears = nCatchAverageYears,
                       ...)
    argsIn$DLL <- "stockassessment"

    args <- argsIn
    args$map$logFScaleMSY <- factor(NA)
    objForecast <- do.call(TMB::MakeADFun, args)
    objForecast$fn()

    ## Get joint precision
    jointPrecision <- TMB::sdreport(objForecast,
                                    fit$opt$par,
                                    svd_solve(fit$sdrep$cov.fixed),
                                    getJointPrecision = TRUE)$jointPrecision

    rp <- c("logFScaleMSY")
    
    ## Find MSY value
    args <- argsIn
    args$parameters$logFScaleMSY <- -1
    args$parameters$implicitFunctionDelta <- 0
    map0 <- args$map
    fix <- setdiff(names(args$parameters), args$random)
    args$map <- lapply(args$parameters[fix], function(x)factor(x*NA))
    args$map <- args$map[names(args$map) != rp]
    args$map$implicitFunctionDelta <- NULL
   
    objOptim <- do.call(TMB::MakeADFun, args)

    objOptim$fn(objOptim$par)
    ## obj$gr(obj$par)

    fn <- Vectorize(function(x){
        objOptim$fn(c(x,0))
        theta <- objOptim$env$last.par
        objOptim$env$f(theta, order = 1)[1,which(names(objOptim$env$last.par) == "implicitFunctionDelta")]
    })

    ## Try different values??
    testStart <- c(-2, -1, -0.5, -0.1, 0, 0.1, 0.25, 0.3, 0.5, 1, 2)
    fnTestStart <- sapply(testStart, fn)
    opt <- nlminb(testStart[which(order(fnTestStart) == 1)], fn, control = nlminb.control)
    ## p0 <- objOptim$par[names(objOptim$par) != "implicitFunctionDelta"]
    ## opt <- nlminb(p0, fn, control = nlminb.control)

    ## Object to do Delta method (no map, no random, delta = 1)
    args <- argsIn
    args$parameters <- objOptim$env$parList(x = opt$par)
    args$parameters$implicitFunctionDelta <- 1
    args$map$logFScaleMSY <- NULL
    args$map$implicitFunctionDelta <- factor(NA)
    args$random <- NULL
    
    objDelta <- do.call(TMB::MakeADFun, args)

    ## Get Jacobian
    gridx <- which(names(objDelta$par) %in% rp)
    JacAll <- jacobian(function(x) objDelta$gr(x)[gridx], objDelta$par, h = jacobianHScale * abs(1e-04 * objDelta$par) + 1e-04 * (abs(objDelta$par) < sqrt(.Machine$double.eps/7e-07)))

    ## Implicit function gradient
    dCdTheta <- -svd_solve(JacAll[,gridx,drop=FALSE]) %*% JacAll[,-gridx,drop=FALSE]
    rownames(dCdTheta) <- rp
    colnames(dCdTheta) <- names(objForecast$env$last.par)


    ## Do delta method
    xtra <- diag(1,length(objForecast$env$last.par.best))
    diag(xtra)[objForecast$env$random] <- 0
    dG <- rbind(xtra[diag(xtra) != 0,,drop = FALSE],dCdTheta)
    covAll <- dG %*% svd_solve(jointPrecision) %*% t(dG)
    covAllOld <- covAll
    ## i <- 21
    ## tv <- ((10^(-i))*10^floor(log10(diag(covAll)[gridx])))
    ## while(tryCatch({solve(covAll);FALSE},error=function(e)TRUE)){
    ##     i <- i-1
    ##     covAll <- covAllOld
    ##     tv <- ((10^(-i))*10^floor(log10(diag(covAll)[gridx])))
    ##     diag(covAll)[gridx] <- diag(covAll)[gridx] + tv
    ## }

    ## Object to do sdreport (delta = 0)
    args <- argsIn
    ## Remvoe rp from map
    args$map <- args$map[!(names(args$map) %in% rp)]
    ## Use optimized parameters
    args$parameters <- objOptim$env$parList(x = opt$par)
    args$parameters$implicitFunctionDelta <- 0

    objSDR <- do.call(TMB::MakeADFun, args)

    
    sdr <- TMB::sdreport(objSDR, objSDR$par, svd_solve(covAll))
    ssdr <- summary(sdr)

    toCI <- function(what){
        exp(ssdr[rownames(ssdr) %in% what,] %*% cbind(Estimate=c(1,0),Low=c(1,-2),High=c(1,2)))
    }
    
    Fmsy <- toCI("logFMSY")
    ssb <- toCI("logssb")
    yield <- toCI("logCatch")
    rec <- toCI("logR")
    fbar <- toCI("logfbar")

    tab <- rbind(Fmsy, ssb[nrow(ssb),], yield[nrow(yield),], rec[nrow(rec),])
    rownames(tab) <- c("Fmsy", "Bmsy", "Yield", "Rmsy")

    rownames(ssb) <- rownames(yield) <- rownames(rec) <- rownames(fbar) <- min(fit$data$years) + 0:(nrow(ssb)-1)

    res <- list(table = tab,
                timeseries = list(SSB = ssb,
                                  Catch = yield,
                                  Recruitment = rec,
                                  Fbar = fbar),
                opt = opt,
                sdr = sdr,
                fbarlabel = substitute(bar(F)[X - Y], list(X = fit$conf$fbarRange[1], Y = fit$conf$fbarRange[2])))
    class(res) <- "sam_forecast_msy"
    res
}


##' Estimate reference points
##'
##' Work in progress - do not use
##' @param fit an object to calculate reference points for
##' @param nYears Number of years to use in per-recruit calculations
##' @param Fsequence Sequence of F values used to report per-recruit and equilibrium values
##' @param aveYears Vector of year indices used to calculate average natural mortality, weights, etc. (starting at 0)
##' @param selYears Vector of year indices used to calculate selectivity (starting at 0)
##' @param SPRpercent Vector of x values for F[x * 100\%] reference points. Default is 0.35.
##' @param catchType Catch type used: (total) catch, landings, discard.
##' @param ... not used
##' @return a sam_referencepoints fit
##' @author Christoffer Moesgaard Albertsen
##' @export
referencepoints <- function(fit,
                            nYears,
                            Fsequence,
                            aveYears,
                            selYears,
                            SPRpercent,
                            catchType,
                            ...){
    UseMethod("referencepoints")
}

##' @rdname referencepoints
##' @method referencepoints sam
#' @export
referencepoints.sam <- function(fit,
                                nYears = 100,
                                Fsequence = seq(0,4, len = 200),
                                aveYears = max(fit$data$years)+(-4:0),
                                selYears = max(fit$data$years),
                                SPRpercent = c(0.35),
                                catchType = "catch",
                                jacobianHScale = 0.5,
                                ...){

    ## Get joint precision
    jointPrecision <- TMB::sdreport(fit$obj,
                               fit$opt$par,
                               solve(fit$sdrep$cov.fixed),
                               getJointPrecision = TRUE)$jointPrecision

    ## Prepare arguments to calculate reference points (fix parameters and latent variables, delta = 1)
    obj0 <- fit$obj
    argsIn <- as.list(obj0$env)[methods::formalArgs(TMB::MakeADFun)[methods::formalArgs(TMB::MakeADFun) != "..."]]
    argsIn$parameters <- fit$pl
    argsIn$random <- unique(names(obj0$env$par[obj0$env$random]))
    ## Add referencepointSet
    catchType <- pmatch(catchType,c("catch","landing","discard"))
    if(is.na(catchType))
        stop("Invalid catch type")

    aveYears <- match(aveYears, fit$data$years) - 1
    if(any(is.na(aveYears)))
        stop("aveYears has years without data.")

    selYears <- match(selYears, fit$data$years) - 1
    if(any(is.na(selYears)))
        stop("selYears has years without data.")

    
    argsIn$data$referencepoint <- list(nYears = nYears,
                                       aveYears = aveYears,
                                       selYears = selYears,
                                       Fsequence = Fsequence,
                                       xPercent = SPRpercent,
                                       catchType = catchType-1
                                       )

    args <- argsIn
    ## Remove random
    args$random <- NULL
    ## Remove referencepoint parameters from map
    map0 <- args$map
    fix <- names(args$parameters) ## setdiff(names(args$parameters), args$random)
    args$map <- lapply(args$parameters[fix], function(x)factor(x*NA))

    if(fit$conf$stockRecruitmentModelCode %in% c(0)){ # RW
        rp <- c("logScaleFmax",
                "logScaleF01",
                "logScaleFxPercent")
    }else if(fit$conf$stockRecruitmentModelCode %in% c(61,63)){ # Hockey-sticks
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                "logScaleFcrash",
                ## "logScaleFext",
                "logScaleFxPercent",
                "logScaleFlim")
    }else if(fit$conf$stockRecruitmentModelCode %in% c(3,62)){ # constant mean, AR
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                "logScaleFxPercent")
    }else if(fit$conf$stockRecruitmentModelCode %in% c(64)){ # Pow CMP
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                "logScaleFxPercent"
                )
    }else if(fit$conf$stockRecruitmentModelCode %in% c(65)){ # Pow Non-CMP
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                "logScaleFxPercent"
                )
    }else if(fit$conf$stockRecruitmentModelCode %in% c(68,69) && fit$pl$rec_par[3] > 0){ ## depensatory recruitment; Fcrash does not work.
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                ## "logScaleFext",
                "logScaleFxPercent"
                )
    }else if(fit$conf$stockRecruitmentModelCode %in% c(90)){
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                "logScaleFcrash",
                ## "logScaleFext",
                "logScaleFxPercent"
                )
       }else if(fit$conf$stockRecruitmentModelCode %in% c(91,92)){
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                ##"logScaleFcrash",
                ## "logScaleFext",
                "logScaleFxPercent"
                )
    }else{
        rp <- c("logScaleFmsy",
                "logScaleFmax",
                "logScaleF01",
                "logScaleFcrash",
                ## "logScaleFext",
                "logScaleFxPercent"
                )
    }
    ## Referencepoints to estimate
    args$map <- args$map[-which(names(args$map) %in% rp)]

    args$parameters$logScaleFmsy <- -1
    args$parameters$logScaleF01 <- -1
    args$parameters$logScaleFmax <- -1
    args$parameters$logScaleFcrash <- -1
    args$parameters$logScaleFext <- -1
    args$parameters$logScaleFxPercent <- rep(-1, length(SPRpercent))
    args$parameters$logScaleFlim <- -1
    args$parameters$implicitFunctionDelta <- 1

    objOptim <- do.call(TMB::MakeADFun, args)
    pStart <- objOptim$par
    
    ## Take inital look at YPR / SPR to determine if Fmax makes sense
    rep <- objOptim$report()
    tryAgain <- FALSE
    if(which.max(rep$logYPR[is.finite(rep$logYPR)]) == length(rep$logYPR[is.finite(rep$logYPR)]) && any(rp %in% "logScaleFmax")){
        warning("The stock does not appear to have a well-defined Fmax. Fmax will not be estimated. Increase the upper bound of Fsequence to try again.")
        rp <- rp[-which(rp %in% "logScaleFmax")]
        args$map$logScaleFmax <- factor(NA)
        tryAgain <- TRUE
    }else if(any(rp %in% "logScaleFmax")){
        pStart[names(pStart) %in% c("logScaleFmax")] <- log(Fsequence[which.max(rep$logYPR[is.finite(rep$logYPR)])]) - log(tail(fbartable(fit)[,"Estimate"],1))
    }
    
    if(any(rp %in% "logScaleFcrash") && min(rep$logSe[is.finite(rep$logSe)], na.rm = TRUE) > -4){
        warning("The stock does not appear to have a well-defined Fcrash. Fcrash will not be estimated. Increase the upper bound of Fsequence to try again.")
        rp <- rp[-which(rp %in% "logScaleFcrash")]
        args$map$logScaleFcrash <- factor(NA)
        tryAgain <- TRUE
    }

    if(any(rp %in% "logScaleFmsy") && which.max(rep$logYe[is.finite(rep$logYe)]) == length(rep$logYe[is.finite(rep$logYe)])){
        warning("The stock does not appear to have a well-defined Fmsy. Fmsy will not be estimated. Increase the upper bound of Fsequence to try again.")
        rp <- rp[-which(rp %in% "logScaleFmsy")]
        args$map$logScaleFmsy <- factor(NA)
        tryAgain <- TRUE
    }else if(any(rp %in% "logScaleFmsy")){
        pStart[names(pStart) %in% c("logScaleFmsy")] <- log(Fsequence[which.max(rep$logYe[is.finite(rep$logYe)])]) - log(tail(fbartable(fit)[,"Estimate"],1))
    }


    

    if(tryAgain)                        
        objOptim <- do.call(TMB::MakeADFun, args)

    opt <- nlminb(pStart, objOptim$fn, objOptim$gr)#, objOptim$he)
    ## ii <- 0
    ## while(max(abs(objOptim$gr(opt$par))) > 1e-4 && ii < 20){
    ##     g <- as.numeric( objOptim$gr(opt$par) )
    ##     h <- objOptim$he(opt$par)
    ##     opt$par <- opt$par - solve(h, g)
    ##     opt$objective <- objOptim$fn(opt$par)
    ##     ii <- ii + 1
    ## }
    ## Object to do Delta method (nothing mapped (that's not mapped in fit$obj, nothing random, delta = 1)
    args <- argsIn
    ## Remove random
    args$random <- NULL
    ## Remvoe rp from map
    args$map <- args$map[!(names(args$map) %in% rp)]
    ## Use optimized parameters
    args$parameters <- objOptim$env$parList(x = opt$par)

    objDelta <- do.call(TMB::MakeADFun, args)

    ## Get Jacobian
    gridx <- which(names(objDelta$par) %in% rp)
    JacAll <- jacobian(function(x) objDelta$gr(x)[gridx], objDelta$par, h = jacobianHScale * abs(1e-04 * objDelta$par) + 1e-04 * (abs(objDelta$par) < sqrt(.Machine$double.eps/7e-07)))

    ## Implicit function gradient
    dCdTheta <- -svd_solve(JacAll[,gridx,drop=FALSE]) %*% JacAll[,-gridx,drop=FALSE]
    rownames(dCdTheta) <- gsub("^logScale","",names(objDelta$par)[gridx])
    colnames(dCdTheta) <- names(fit$obj$env$last.par)

    ## Do delta method
    xtra <- diag(1,length(fit$obj$env$last.par.best))
    diag(xtra)[fit$obj$env$random] <- 0
    dG <- rbind(xtra[diag(xtra) != 0,,drop = FALSE],dCdTheta)
    covAll <- dG %*% svd_solve(jointPrecision) %*% t(dG)
    covAllOld <- covAll
    i <- 21
    ## tv <- ((10^(-i))*10^floor(log10(diag(covAll)[gridx])))
    ## while(!all(eigen(covAll)$values > 1e-8)){
    ##     i <- i-1
    ##     covAll <- covAllOld
    ##     tv <- ((10^(-i))*10^floor(log10(diag(covAll)[gridx])))
    ##     diag(covAll)[gridx] <- diag(covAll)[gridx] + tv
    ## }

    ## Object to do sdreport (delta = 0)
    args <- argsIn
    ## Remvoe rp from map
    args$map <- args$map[!(names(args$map) %in% rp)]
    ## Use optimized parameters
    args$parameters <- objOptim$env$parList(x = opt$par)
    args$parameters$implicitFunctionDelta <- 0

    objSDR <- do.call(TMB::MakeADFun, args)

    
    sdr <- TMB::sdreport(objSDR, objSDR$par, svd_solve(covAll))
    ssdr <- summary(sdr)

    toCI <- function(what){
        tmp <- ssdr[rownames(ssdr) == what,,drop=FALSE]
        CI <- exp(tmp %*% cbind(CIL=c(1,-2),CIH=c(1,2)))
        cbind(Estimate = exp(tmp[,1]), CI)
    }

    Ftab <- do.call("rbind",sapply(unique(rownames(ssdr)[grepl("referencepoint.logF",rownames(ssdr))]),
                     toCI, simplify = FALSE))
    Btab <- do.call("rbind",sapply(unique(rownames(ssdr)[grepl("referencepoint.logB",rownames(ssdr))]),
                                   toCI, simplify = FALSE))
    Rtab <- do.call("rbind",sapply(unique(rownames(ssdr)[grepl("referencepoint.logR",rownames(ssdr))]),
                                   toCI, simplify = FALSE))
    Ytab <- do.call("rbind",sapply(unique(rownames(ssdr)[grepl("referencepoint.logY",rownames(ssdr)) & !grepl("referencepoint.logYPR",rownames(ssdr))]),
                     toCI, simplify = FALSE))
    SPRtab <- do.call("rbind",sapply(unique(rownames(ssdr)[grepl("referencepoint.logSPR",rownames(ssdr))]),
                                   toCI, simplify = FALSE))
    YPRtab <- do.call("rbind",sapply(unique(rownames(ssdr)[grepl("referencepoint.logYPR",rownames(ssdr))]),
                                   toCI, simplify = FALSE))
    colnames(Ftab) <- colnames(Btab) <- colnames(Rtab) <- colnames(Ytab) <- colnames(SPRtab) <- colnames(YPRtab) <- c("Estimate","Low","High")

    toRowNames <- Vectorize(function(x){
        switch(gsub("^referencepoint.logF","",x),
               "sq"="Status quo",
               "0"="Zero catch",
               "msy"="MSY",
               "max"="Max",
               "01"="0.1",
               "crash"="Crash",
               "ext"="Ext",
               "xPercent"=NA,
               "lim"="lim",
               x
        )               
    })
    rn <- toRowNames(rownames(Ftab))
    rn[is.na(rn)] <- sapply(SPRpercent,function(x)sprintf("%s%%",x * 100))    
    rownames(Ftab) <- rownames(Btab) <- rownames(Rtab) <- rownames(Ytab) <- rownames(SPRtab) <- rownames(YPRtab) <- rn

    ## Ftab["Ext",c("Low","High")] <- NA
    ## Btab["Ext",c("Low","High")] <- NA
    ## Rtab["Ext",c("Low","High")] <- NA
    ## Ytab["Ext",c("Low","High")] <- NA
    ## SPRtab["Ext",c("Low","High")] <- NA
    ## YPRtab["Ext",c("Low","High")] <- NA
    
    YPRseq <- toCI("logYPR")
    SPRseq <- toCI("logSPR")
    Yieldseq <- toCI("logYe")
    Bseq <- toCI("logSe")
    Rseq <- toCI("logRe")

    rownames(YPRseq) <- rownames(SPRseq) <- rownames(Yieldseq) <- rownames(Bseq) <- rownames(Rseq) <- argsIn$data$referencepoint$Fsequence
    
    res <- list(tables = list(F = Ftab,
                              Yield = Ytab,
                              YieldPerRecruit = YPRtab,
                              SpawnersPerRecruit = SPRtab,
                              Biomass = Btab,
                              Recruitment = Rtab
                             ),
                graphs = list(F = argsIn$data$referencepoint$Fsequence,
                              Yield = Yieldseq,
                              YieldPerRecruit = YPRseq,
                              SpawnersPerRecruit = SPRseq,
                              Biomass = Bseq,
                              Recruitment = Rseq),
                opt = opt,
                sdr = sdr,
                fbarlabel = substitute(bar(F)[X - Y], list(X = fit$conf$fbarRange[1], Y = fit$conf$fbarRange[2]))## ,
                ## diagonalCorrection = tv
                )
                              


    class(res) <- "sam_referencepoints"
    return(res)
}

##' @export   
plot.sam_referencepoints <- function(x,
                                     show = c(1L:3L,5L),
                                     estimates = c("Status quo", "MSY"),
                                     ask = TRUE,
                                     legend.args = list(x = "top", ncol = length(estimates)),
                                     ...){

    estimates <- match.arg(estimates,
                           choices = rownames(x$tables$F),
                           several.ok = TRUE)

    if(ask){
        oask <- grDevices::devAskNewPage(TRUE)
        on.exit(grDevices::devAskNewPage(oask))
    }


      toReportNames <- Vectorize(function(x,type = "F"){
        paste0("referencepoint.log",type,switch(x,
                                                "Status quo"="sq",
                                                "Zero catch"="0",
                                                "MSY" = "msy",
                                                "Max" = "max",
                                                "0.1"="01",
                                                "Crash"="crash",
                                                "Ext"="ext",
                                                "lim"="lim",
                                                "xPercent"
                                                )
               )
        })
 
    

    doPlot <- function(y){
        getACol <- function(col, a){
            do.call("rgb",c(as.list(col2rgb(col,TRUE))[-4],
                            list(alpha = a * 255),
                            list(maxColorValue = 255)))
        }
        yp <- pmatch(y,names(x$graphs))
        yt <- pmatch(y,names(x$tables))
        if(is.na(yp) || is.na(yt))
            stop("Error message")
        tmpf <- x$tables$F["Crash",1]
        tmpval <- x$graphs[[yp]]
        if(!is.na(tmpf))
            tmpval <- x$graphs[[yp]][abs(x$graphs$F -tmpf) > 0.1,]
        plot(x$graphs$F, x$graphs[[yp]][,1], type = "n", ylim = range(tmpval, finite = TRUE, na.rm = TRUE),
             xlab = x$fbarlabel, ylab = gsub("([a-z])([A-Z])", "\\1-\\2",names(x$graphs)[yp]),
             main = paste("Equilibrium",tolower(gsub("([a-z])([A-Z])", "\\1 \\2",names(x$graphs)[yp]))))
        polygon(c(x$graphs$F, rev(x$graphs$F)),
                c(x$graphs[[yp]][,2], rev(x$graphs[[yp]][,3])),
                col = getACol(1,0.3),
                border = NA)
        lines(x$graphs$F, x$graphs[[yp]][,1], col = 1, lwd = 3)
        for(j in seq_along(estimates)){
            r <- estimates[j]
            r <- pmatch(r, rownames(x$tables$F))
            if(is.na(r))
                stop("Error message 2")
            if(!is.na(x$tables$F[r,"Estimate"])){
                acol <- getACol(j+1, 0.2)
                usr <- par("usr")
                xvals <- x$tables$F[r,]
                yvals <- x$tables[[yt]][r,]
                polygon(c(usr[1], xvals[2], xvals[2], xvals[3], xvals[3], usr[1]),
                        c(yvals[2], yvals[2], usr[3], usr[3], yvals[3], yvals[3]),
                        border = NA,
                        col = acol)
                segments(xvals[1], usr[3], xvals[1], yvals[1],
                         col = j+1, lwd = 3, lty = 1)
                segments(usr[1], yvals[1], xvals[1], yvals[1],
                         col = j+1, lwd = 3, lty = 1)
                
            }
        }

        if(!is.null(legend.args)){
            defArgs <- list(legend = estimates,
                            lwd = 3,
                            fill = sapply(seq_along(estimates)+1, getACol, a = 0.2),
                            border = NA,
                            merge = TRUE,
                            title = "Reference points",
                            col = seq_along(estimates)+1)
            do.call(graphics::legend,
                    c(legend.args,defArgs[which(!names(defArgs) %in% names(legend.args))])
                    )
        }
    }
    
    bshow <- rep(FALSE, 5)
    if(is.character(show)){
        show <- na.omit(pmatch(show, c("YieldPerRecruit", "SpawnersPerRecruit", "Yield", "Biomass", "Recruitment")))
    }
        
    bshow[show[show %in% (1:length(bshow))]] <- TRUE    
    ## YPR
    if(bshow[1L]){
        doPlot("YieldPerRecruit")
    }
    ## SPR
    if(bshow[2L]){ 
        doPlot("SpawnersPerRecruit")
    }
    ## Yield
    if(bshow[3L]){                       
        doPlot("Yield")
    }
    ## Biomass
    if(bshow[4L]){                       
        doPlot("Biomass")
    }
    ## Recruitment
    if(bshow[5L]){                       
        doPlot("Recruitment")
    }
}