# library(evd)

PLIsuperquantile = function(order,x,y,deltasvector,InputDistributions,type="MOY",samedelta=TRUE,percentage=TRUE,nboot=0,conf=0.95,bootsample=TRUE,bias=TRUE){
  
  # Deux manieres d'estimer un superquantile d'ordre p a partir d'un quantile q d'ordre p et d'un echantillon x :
  #   sq <- mean(x[x>q])
  #   sq <- mean(x*(x>q)/(1-p))
  
  # This function allows the estimation of Density Modification Based Reliability Sensitivity Indices
  # called PLI (Perturbed-Law based sensitivity Indices) for a superquantile
  # Author: Paul Lemaitre, Bertrand Iooss, Thibault Delage and Roman Sueur
  #
  # Refs : P. Lemaitre, E. Sergienko, A. Arnaud, N. Bousquet, F. Gamboa and B. Iooss.
  #        Density modification based reliability sensitivity analysis, 
  #        Journal of Statistical Computation and Simulation, 85:1200-1223, 2015.
  #        hal.archives-ouvertes.fr/docs/00/73/79/78/PDF/Article_v68.pdf.
  #
  #        R. Sueur, B. Iooss and T. Delage. 
  #        Sensitivity analysis using perturbed-law based indices for quantiles and application to an industrial case}, 
  #        10th International Conference on Mathematical Methods in Reliability (MMR 2017), Grenoble, France, July 2017.
  #
  ###################################
  ## Description of input parameters
  ###################################
  #  
  # order is the order of the superquantile to estimate.
  # x is the matrix of simulation points coordinates (one column per variable).
  # y is the vector of model outputs.
  # deltasvector is a vector containing the values of delta for which the indices will be computed
  # InputDistributions is a list of list. Each list contains, as a list, the name of the distribution to be used and the parameters.
  #   Implemented cases so far:
  #		  - for a mean perturbation: Gaussian, Uniform, Triangle, Left Trucated Gaussian, Left Truncated Gumbel
  #		  - for a variance perturbation: Gaussian, Uniform
  # type is a character string in which the user will specify the type of perturbation wanted. 
  #	NB: the sense of "deltasvector" varies according to the type of perturbation
  #	type can take the value "MOY",in which case deltasvector is a vector of perturbated means.
  #	type can take the value "VAR",in which case deltasvector is a vector of perturbated variances, therefore needs to be positive integers.
  # samedelta is a boolean used with the value "MOY" for type. If it is set at TRUE, the mean perturbation will be the same for all the variables. 
  #   If not, the mean perturbation will be new_mean = mean+sigma*delta where mean, sigma are parameters defined in InputDistributions and delta is a value of deltasvector. See subsection 4.3.3 of the reference for an exemple of use. 
  # percentage defines the formula used for the PLI. If percentage=FALSE, the initially proposed formula is used (Sueur et al., 2017).
  #   If percentage=TRUE, the PLI is given in percentage of variation of the quantile (even if it is negative).
  # nboot is the number of bootstrap replicates
  # conf is the required bootstrap confidence interval
  # bootsample defines if the sampling uncertainty is taken into account in computing the boostrap confidence intervals of the PLI
  # bias defines which type of PLI-superquantile is computed:
  #   "TRUE" gives the mean of outputs above the perturbed quantile (alternative formula)
  #   "FALSE" gives the the mean of perturbed outputs above the perturbed quantile (original formula)
  
  #
  ###################################
  ## Description of output parameters
  ###################################
  #
  # The output is a matrix where the PLI are stored:
  #		each column corresponds to an input, each line corresponds to a twist of amplitude delta
  
  ########################################
  ## Creation of local variables	
  ########################################
  
  nmbredevariables=dim(x)[2]		# number of variables
  nmbredepoints=dim(x)[1]			# number of points
  nmbrededeltas=length(deltasvector)	# number of perturbations
  
  ## some storage matrices 
  I <- J <- ICIinf <- ICIsup <- JCIinf <- JCIsup <- matrix(0,ncol=nmbredevariables,nrow=nmbrededeltas) 
  colnames(I) <- colnames(J) <- colnames(ICIinf) <- colnames(ICIsup) <- colnames(JCIinf) <- colnames(JCIsup) <- lapply(1:nmbredevariables, function(k) paste("X",k,sep="_", collapse=""))
  
  ########################################
  ## Definition of useful functions used further on 
  ########################################
  
  ########################################
  ##	Simpson's method
  ########################################
  simpson_v2 <- function(fun, a, b, n=100) {
    # numerical integral using Simpson's rule
    # assume a < b and n is an even positive integer
    if (a == -Inf & b == Inf) {
      f <- function(t) (fun((1-t)/t) + fun((t-1)/t))/t^2
      s <- simpson_v2(f, 0, 1, n)
    } else if (a == -Inf & b != Inf) {
      f <- function(t) fun(b-(1-t)/t)/t^2
      s <- simpson_v2(f, 0, 1, n)
    } else if (a != -Inf & b == Inf) {
      f <- function(t) fun(a+(1-t)/t)/t^2
      s <- simpson_v2(f, 0, 1, n)
    } else {
      h <- (b-a)/n
      x <- seq(a, b, by=h)
      y <- fun(x)
      y[is.nan(y)]=0
      s <- y[1] + y[n+1] + 2*sum(y[seq(2,n,by=2)]) + 4 *sum(y[seq(3,n-1, by=2)])
      s <- s*h/3
    }
    return(s)
  }
  
  transinverse <- function(a,b,c) {
    # useful to compute bootstrap-based confidence intervals
    if (a > c) ans <- a / b - 1
    else ans <- 1 - b / a
    return(ans)
  }
  
  ########################################
  ## Principal loop of the function 
  ########################################
  
  quantilehat <- quantile(y,order) # quantile estimate
  sqhat <- mean( y[y >= quantilehat] ) # superquantile estimate
  
  ys = sort(y,index.return=T) # ordered output
  xs = x[ys$ix,] # inputs ordered by increasing output
  
  for (i in 1:nmbredevariables){		# loop for each variable
    ## definition of local variables
    Loi.Entree=InputDistributions[[i]]
    lqid=rep(0,length=nmbrededeltas) 
    
    if (nboot > 0){
      lqidb=matrix(0,nrow=nmbrededeltas,ncol=nboot) # pour bootstrap 
      sqhatb=NULL
    }
    
    if (type=="MOY"){
      ############################
      ## definition of local variable vdd
      ############################
      if(!samedelta){
        # In this case, the  mean perturbation will be new_mean = mean+sigma*delta
        # The mean and the standard deviation sigma of the input distribution must be stored in the third place of the list defining the input distribution.
        moy=Loi.Entree[[3]][1]
        sigma=Loi.Entree[[3]][2]
        vdd=moy+deltasvector*sigma
      } else {
        vdd=deltasvector
      }
      
      ##########################
      ### The next part does, for each kind of input distribution
      # 	Solve with respect to lambda the following equation :
      #		(1) Mx'(lambda)/Mx(lambda)-delta=0 {See section 3, proposition 3.2}
      #	One can note that (1) is the derivative with respect to lambda of
      #		(2) log(Mx(lambda))-delta*lambda
      # 	Function (2) is concave, therefore its optimisation is theoritically easy.
      #
      #	=> One obtains an unique lambda solution
      #	
      #	Then the density ratio is computed and summed, allowing the estimation of q_i_delta. 
      #	lqid is a vector of same length as  deltas_vector
      #	sigma2_i_tau_N, the estimator of the variance of the estimator of P_i_delta (see lemma 2.1) is also computed
      #
      #	Implemented cases: Gaussian, Uniform, Triangle, Left Trucated Gaussian, Left Truncated Gumbel
      if ( Loi.Entree[[1]] =="norm"||Loi.Entree[[1]] =="lnorm"){
        # if the input is a Gaussian,solution of equation (1) is trivial
        mu=Loi.Entree[[2]][1]
        sigma=Loi.Entree[[2]][2]
        phi=function(tau){mu*tau+(sigma^2*tau^2)/2}
        
        vlambda=(vdd-mu)/sigma^2
      }	# end for Gaussian input, mean twisting
      
      if (  Loi.Entree[[1]] =="unif"){
        # One will not minimise directly log(Mx)-lambda*delta due to numerical problems emerging when considering
        #	exponential of large numbers (if b is large, problems can be expected) 
        # Instead, one note that the optimal lambda for an Uniform(a,b) and a given mean delta is the same that for
        #	an Uniform(0,b-a) and a given mean (delta-a).
        # Function phit corresponding to the log of the Mgf of an U(0,b-a) is implemented; 
        #	the function expm1 is used to avoid numerical troubles when tau is small.
        # Function gt allowing to minimise phit(tau)-(delta-a)*tau is also implemented.
        a=Loi.Entree[[2]][1]
        b=Loi.Entree[[2]][2]
        m=(a+b)/2
        
        Mx=function(tau){
          if (tau==0){ 1 }
          else {(exp(tau*b)-exp(tau*a) )/ ( tau * (b-a))}
        }
        phi=function(tau){
          if(tau==0){0}
          else { log ( Mx(tau))}
        }	
        phit=function(tau){
          if (tau==0){0}
          else {log(expm1(tau*(b-a)) / (tau*(b-a)))}
        }
        gt=function(tau,delta){ 
          phit(tau) -(delta-a)*tau
        }
        vlambda=c();
        for (l in 1:nmbrededeltas){
          tm=nlm(gt,0,vdd[l])$estimate					
          vlambda[l]=tm					
        } 	
      }	# end for Uniform input, mean twisting
      
      if (  Loi.Entree[[1]] =="triangle"){
        # One will not minimise directly log(Mx)-lambda*delta due to numerical problems emerging when considering
        #	exponential of large numbers (if b is large, problems can be expected) 
        # Instead, one note that the optimal lambda for an Triangular(a,b,c) and a given mean delta is the same that for
        #	an Uniform(0,b-a,c-a) and a given mean (delta-a).
        # Function phit corresponding to the log of the Mgf of an Tri(0,b-a,c-a) is implemented;
        #	One can note that phit=log(Mx)+lambda*a
        # Function gt allowing to minimise phit(tau)-(delta-a)*tau is also implemented..
        a=Loi.Entree[[2]][1]
        b=Loi.Entree[[2]][2]
        c=Loi.Entree[[2]][3] # reminder: c is between a and b
        m=(a+b+c)/3	
        
        Mx=function(tau){
          if (tau !=0){
            dessus=(b-c)*exp(a*tau)-(b-a)*exp(c*tau)+(c-a)*exp(b*tau)
            dessous=(b-c)*(b-a)*(c-a)*tau^2
            return ( 2*dessus/dessous)
          } else {
            return (1)
          }
        }
        phi=function(tau){return (log (Mx(tau)))}
        
        phit=function(tau){
          if(tau!=0){
            dessus=(a-b)*expm1((c-a)*tau)+(c-a)*expm1((b-a)*tau)
            dessous=(b-c)*(b-a)*(c-a)*tau^2
            return( log (2*dessus/dessous) )
          } else { return (0)}
        }
        gt=function(tau,delta){ 
          phit(tau)-(delta-a)*tau
        }
        vlambda=c();
        for (l in 1:nmbrededeltas){
          tm=nlm(gt,0,vdd[l])$estimate					
          vlambda[l]=tm					
        } 
      }	# End for Triangle input, mean twisting
      
      if (  Loi.Entree[[1]] =="tnorm"){
        # The case implemented is the left truncated Gaussian
        # Details :	First, the constants defining the distribution (mu, sigma, min) are extracted.
        #		Then, the function g is defined as log(Mx(tau))-delta*tau. 
        #		The function phi has an explicit expression in this case.
        mu=Loi.Entree[[2]][1]
        sigma=Loi.Entree[[2]][2]
        min=Loi.Entree[[2]][3]
        
        phi=function(tau){
          mpls2=mu+tau*sigma^2
          Fa=pnorm(min,mu,sigma)		
          Fia=pnorm(min,mpls2,sigma)
          lMx=mu*tau+1/2*sigma^2*tau^2 - (1-Fa) + (1-Fia)
          return(lMx)
        }
        
        g=function(tau,delta){ 
          if (tau == 0 ){	return(0)
          } else {	return(phi(tau) -delta*tau)}
        }
        vlambda=c();
        for (l in 1:nmbrededeltas){
          tm=nlm(g,0,vdd[l])$estimate					
          vlambda[l]=tm					
        } 
      } 	# End for left truncated Gaussian, mean twisting
      
      
      if (  Loi.Entree[[1]] =="tgumbel"){
        # The case implemented is the left truncated Gumbel
        # Details :	First, the constants defining the distribution (mu, beta, min) are extracted.
        #		Then, the function g is defined as log(Mx(tau))-delta*tau. 
        #		The function Mx is estimated as described in annex C, the unknonw integrals are estimated with Simpson's method
        #		One should be warned that the MGF is not defined if tau> 1/beta
        #		The function Mx prime is also defined as in annex C.
        #		Then a dichotomy is performed to find the root of equation (1)
        mu=Loi.Entree[[2]][1]
        beta=Loi.Entree[[2]][2]
        min=Loi.Entree[[2]][3]
        vraie_mean=mu-beta*digamma(1)
        
        estimateurdeMYT=function(tau){
          if(tau>1/beta){ print("Warning, the MGF of the truncated gumbel distribution is not defined")}
          if (tau!=0){
            fctaint=function(y){evd::dgumbel(y,mu,beta)*exp(tau*y)}
            partie_tronquee=simpson_v2(fctaint,-Inf,min,2000)
            MGFgumbel=exp(mu*tau)*gamma(1-beta*tau)
            res=(MGFgumbel-partie_tronquee)	/ (1-evd::pgumbel(min,mu,beta)) 
            return(res)
          } else { return (1)}
        }
        estimateurdeMYTprime=function(tau){
          fctaint=function(y){y*evd::dgumbel(y,mu,beta)*exp(tau*y)}
          partie_tronquee=simpson_v2(fctaint,-Inf,min,2000)
          MGFprimegumbel=exp(mu*tau)*gamma(1-beta*tau)*(mu-beta*digamma(1-beta*tau))
          Mxp=(MGFprimegumbel-partie_tronquee)/(1-evd::pgumbel(min,mu,beta))
          return(Mxp)
        }
        phi=function(tau){
          return(log(estimateurdeMYT(tau)))
        }
        g=function(tau,delta){
          Mx=estimateurdeMYT(tau)
          Mxp=estimateurdeMYTprime(tau)
          return(Mxp/Mx-delta)
        }
        
        vlambda=c()
        vmax_search=1/beta -10^-8 #Maximal theoritical value of lambda, with some safety
        precision=10^-8
        
        for (l in 1:nmbrededeltas){
          d=vdd[l]
          t=vmax_search
          a=g(t,d)
          while(a>0){t=t-5*10^-4
          a=g(t,d)
          }
          t1=t;t2=t+5*10^-4 #g(t1) is negative; g(t2) positive
          while(abs(g(t,d))>precision){
            t=(t1+t2)/2
            if ( g(t,d)<0 ){t1=t} else {t2=t}
          }
          vlambda[l]=t					
        } 	
      }	# End for left trucated Gumbel, mean twisting
      
      
      
      ###############################################################
      ############# Computation of q_i_delta for the mean twisting
      ###############################################################
      
      #    ecdfy <- ecdf(y)
      for (K in 1:nmbrededeltas){
        if(vdd[K]!=0){
          res=NULL ; respts=NULL	
          pti=phi(vlambda[K])
          for (j in 1:nmbredepoints){	
            res[j]=exp(vlambda[K]*xs[j,i]-pti)
            respts[j]=exp(vlambda[K]*x[j,i]-pti)
          }
          sum_res = sum(res)
          kid = 1
          res1 = res[1]
          res2 = res1/sum_res
          while (res2 < order){
            kid = kid + 1
            res1 = res1 + res[kid]
            res2 = res1/sum_res
          }
          if (bias){ lqid[K] = mean(y[y >= ys$x[kid]]) # ys$x[kid] = quantile
          } else lqid[K] = mean(y * respts * ( y >= ys$x[kid] ) / (1-order))
        } else lqid[K] = sqhat
      }
      
      ###############################################################
      ##########              BOOTSTRAP                ###############
      ###############################################################
      
      if (nboot >0){
        for (b in 1:nboot){
          ib <- sample(1:length(y),replace=TRUE)
          xb <- x[ib,]
          yb <- y[ib]
          #        ecdfyb <- ecdf(yb)
          
          quantilehatb <- quantile(yb,order) # quantile estimate
          sqhatb <- c(sqhatb, mean( yb * (yb >= quantilehatb) / ( 1 - order ))) # superquantile estimate
          
          ysb = sort(yb,index.return=T) # ordered output
          xsb = xb[ysb$ix,] # inputs ordered by increasing output
          
          for (K in 1:nmbrededeltas){
            if(vdd[K]!=0){
              res=NULL ; respts=NULL	
              pti=phi(vlambda[K])
              for (j in 1:nmbredepoints){	
                res[j]=exp(vlambda[K]*xsb[j,i]-pti)
                respts[j]=exp(vlambda[K]*xb[j,i]-pti)
              }
              sum_res = sum(res)
              kid = 1
              res1 = res[1]
              res2 = res1/sum_res
              while (res2 < order){
                kid = kid + 1
                res1 = res1 + res[kid]
                res2 = res1/sum_res
              }
              if (bias){ lqidb[K,b] = mean(yb[yb >= ysb$x[kid]]) # ysb$x[kid] = quantile
              } else lqidb[K,b] = mean(yb * respts * (yb >= ysb$x[kid] ) / (1-order))
            } else lqidb[K,b] = sqhatb[b]
          }
        } # end of bootstrap loop
      }  
      
    } # endif type="MOY"
    
    ######################################################################################
    
    if (type=="VAR"){
      ### The next part does, for each kind of input distribution
      # 	Solve with respect to lambda the following set of equations :
      #		int (y.f_lambda(y)dy) = int( yf(y)dy)
      #	 (3)	int (y^2.f_lambda(y)dy)= V_f + int( yf(y)dy) ^2
      #	One must note that lambda is of size 2.
      #
      # Implemented cases : Gaussian, Uniform
      if ( Loi.Entree[[1]] =="norm"||Loi.Entree[[1]] =="lnorm"){
        # if the input is a Gaussian,solution of equation (3) is given by analytical devlopment
        mu=Loi.Entree[[2]][1]
        sigma=Loi.Entree[[2]][2]
        phi1=function(l){	
          t1=exp(-mu^2/(2*sigma^2))
          t2=exp((mu+sigma^2*l[1])^2/(2*sigma^2*(1-2*sigma^2*l[2])))
          t3=1/sqrt(1-2*sigma^2*l[2])
          
          return(log(t1*t2*t3))
        }
        
        lambda1=mu*(1/deltasvector-1/sigma^2)	
        lambda2=-1/2*(1/deltasvector-1/sigma^2)
        # nota bene : lambda1 and lambda2 are vectors of size nmbrededeltas
      } # End for Gaussian input, variance twisting
      
      if (  Loi.Entree[[1]] =="unif"){
        # Details :	First, the constants defining the distribution (a, b) are extracted.
        #		Then, the function phi1 is defined, the unknonw integrals are estimated with Simpson's method
        #		The Hessian of the Lagrange function is then defined (See annex B)
        #		Then, for each perturbed variance, the Lagrange function and its gradient are defined and minimised.
        a=Loi.Entree[[2]][1]
        b=Loi.Entree[[2]][2]
        m=(a+b)/2
        
        lambda1=c()
        lambda2=c()
        
        phi1=function(l){ # l is a vector of size 2, resp lambda1, lambda2
          fctaint=function(y){dunif(y,a,b)*exp(l[1]*y+l[2]*y*y)}
          cste=simpson_v2(fctaint,a,b,2000)
          return(log(cste))
        }
        
        
        hess=function(l){	# the Hessian of the Lagrange function
          epl=exp(phi1(l))
          
          fctaint=function(y){y*dunif(y,a,b)*exp(l[1]*y+l[2]*y*y)}
          cste=simpson_v2(fctaint,a,b,2000)
          r1=cste/epl
          
          fctaint=function(y){y*y*dunif(y,a,b)*exp(l[1]*y+l[2]*y*y)}
          cste=simpson_v2(fctaint,a,b,2000)
          r2=cste/epl
          
          fctaint=function(y){y*y*y*dunif(y,a,b)*exp(l[1]*y+l[2]*y*y)}
          cste=simpson_v2(fctaint,a,b,2000)
          r3=cste/epl
          
          fctaint=function(y){y*y*y*y*dunif(y,a,b)*exp(l[1]*y+l[2]*y*y)}
          cste=simpson_v2(fctaint,a,b,2000)
          r4=cste/epl
          
          h11=r2-(r1*r1)
          h21=r3-(r1*r2)
          h22=r4-(r2*r2)
          return(matrix(c(h11,h21,h21,h22),ncol=2,nrow=2))
        }
        
        # The lagrange function and its gradient must be redefined for each delta (i.e. for each fixed variance)
        for (w in 1:nmbrededeltas){
          
          gr=function(l){	# the gradient of the lagrange function
            epl=exp(phi1(l))
            
            fctaint=function(y){y*dunif(y,a,b)*exp(l[1]*y+l[2]*y*y)}
            cste=simpson_v2(fctaint,a,b,2000)
            resultat1=cste/epl-m
            
            fctaint=function(y){y*y*dunif(y,a,b)*exp(l[1]*y+l[2]*y*y)}
            cste=simpson_v2(fctaint,a,b,2000)
            resultat2=cste/epl-(deltasvector[w]+m^2)
            
            return(c(resultat1,resultat2))
          }
          
          
          lagrangefun=function(l){
            res=phi1(l)-l[1]*m-l[2]*(deltasvector[w]+m^2)
            attr(res, "gradient")=gr(l)
            attr(res, "hessian")=hess(l)
            return(res)
          }
          v=nlm(lagrangefun,c(0,-1))$estimate
          
          lambda1[w]=v[1]
          lambda2[w]=v[2]
        }
      }  # End for Uniform input, variance twisting
      
      
      ###############################################################
      ############# Computation of q_i_delta for the variance twisting
      ###############################################################
      for (K in 1:nmbrededeltas){
        if(deltasvector[K]!=0){
          res=NULL ; respts=NULL
          pti=phi1(c(lambda1[K],lambda2[K]))
          for (j in 1:nmbredepoints){	
            res[j]=exp(lambda1[K]*xs[j,i]+lambda2[K]*xs[j,i]^2-pti) 
            respts[j]=exp(lambda1[K]*x[j,i]+lambda2[K]*x[j,i]^2-pti) 
          }
          sum_res = sum(res)
          kid = 1
          res1 = res[1]
          res2 = res1/sum(res)
          while (res2 < order){
            kid = kid + 1
            res1 = res1 + res[kid]
            res2 = res1/sum_res
          }
          if (bias){ lqid[K] = mean(y[y >= ys$x[kid]]) # ys$x[kid] = quantile
          } else lqid[K] = mean(y * respts * ( y >= ys$x[kid] ) / (1-order))
        } else lqid[K] = sqhat
      }
      
      ###############################################################
      ##########              BOOTSTRAP                ###############
      ###############################################################
      
      if (nboot >0){
        for (b in 1:nboot){
          ib <- sample(1:length(y),replace=TRUE)
          xb <- x[ib,]
          yb <- y[ib]
          
          quantilehatb <- quantile(yb,order) # quantile estimate
          sqhatb <- c(sqhatb, mean( yb * (yb >= quantilehatb) / ( 1 - order ))) # superquantile estimate
          
          ysb = sort(yb,index.return=T) # ordered output
          xsb = xb[ysb$ix,] # inputs ordered by increasing output
          
          for (K in 1:nmbrededeltas){
            if(deltasvector[K]!=0){
              res=NULL ; respts=NULL
              pti=phi1(c(lambda1[K],lambda2[K]))
              for (j in 1:nmbredepoints){	
                res[j]=exp(lambda1[K]*xsb[j,i]+lambda2[K]*xsb[j,i]^2-pti) 
                respts[j]=exp(lambda1[K]*xb[j,i]+lambda2[K]*xb[j,i]^2-pti) 
              }
              sum_res = sum(res)
              kid = 1
              res1 = res[1]
              res2 = res1/sum(res)
              while (res2 < order){
                kid = kid + 1
                res1 = res1 + res[kid]
                res2 = res1/sum_res
              }
              if (bias){ lqidb[K,b] = mean(yb[yb >= ysb$x[kid]]) # ysb$x[kid] = quantile
              } else lqidb[K,b] = mean(yb * respts * (yb >= ysb$x[kid] ) / (1-order))
            } else lqidb[K,b] = sqhatb[b]
          }
        } # end of bootstrap loop
      }  
      
    } # endif TYPE="VAR"
    
    ########################################
    ## Plugging estimator of the S_i_delta indices
    ########################################	
    
    for (j in 1:length(lqid)){
      J[j,i]=lqid[j]
      if (percentage==FALSE) I[j,i]=transinverse(lqid[j],sqhat,sqhat)
      else I[j,i]=lqid[j]/sqhat-1
      
      if (nboot > 0){
        # ICI = PLI bootstrap including or excluding sampling uncertainty
        # JCI = superquantile bootstrap 
        sqinf <- quantile(lqidb[j,],(1-conf)/2)
        sqsup <- quantile(lqidb[j,],(1+conf)/2)
        JCIinf[j,i]=sqinf
        JCIsup[j,i]=sqsup
        sqb <- mean(sqhatb)
        if (percentage==FALSE){
          if (bootsample){
            ICIinf[j,i]=transinverse(sqinf,sqb,sqb)
            ICIsup[j,i]=transinverse(sqsup,sqb,sqhat)
          } else{
            ICIinf[j,i]=quantile(transinverse(lqidb[j,],sqhatb,sqhatb),(1-conf)/2)
            ICIsup[j,i]=quantile(transinverse(lqidb[j,],sqhatb,sqhatb),(1+conf)/2)
          }
        } else {
          if (bootsample){
            ICIinf[j,i]=sqinf/sqb-1
            ICIsup[j,i]=sqsup/sqb-1
          } else{
            ICIinf[j,i]=quantile((lqidb[j,]/sqhatb-1),(1-conf)/2)
            ICIsup[j,i]=quantile((lqidb[j,]/sqhatb-1),(1+conf)/2)
          }
        }
      }
    }
    
  }	# End for each input
  
  res <- list(PLI = I, PLICIinf = ICIinf, PLICIsup = ICIsup, superquantile = J, superquantileCIinf = JCIinf, superquantileCIsup = JCIsup)
  
  return(res)
}