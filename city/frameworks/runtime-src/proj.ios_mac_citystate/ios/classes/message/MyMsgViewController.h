//
//  MyMsgViewController.h
//  qmap
//
//  Created by hf on 15/9/1.
//
//

/*
 *【消息】--->[我的消息]界面
 *功能：查看我的消息
 */

#import "BaseViewController.h"

@interface MyMsgViewController : BaseViewController<UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, retain) UITableView * listTableView;

@end